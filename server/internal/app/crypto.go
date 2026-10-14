package app

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"os"
	"sort"
	"strings"
)

func randBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		panic("crypto/rand failed: " + err.Error())
	}
	return b
}

var idEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// newID returns prefix + 16 lowercase base32 chars (80 random bits).
func newID(prefix string) string {
	return prefix + strings.ToLower(idEncoding.EncodeToString(randBytes(10)))
}

// newToken returns a device token: "sf_" + 256 random bits, base64url.
func newToken() string {
	return "sf_" + base64.RawURLEncoding.EncodeToString(randBytes(32))
}

// hashToken is how tokens are stored: hex SHA-256 (tokens are high-entropy, so no salt/KDF needed).
func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

// Pairing codes: no 0/O, 1/I/L. 31^6 ≈ 887M combinations, formatted XXX-XXX.
const pairAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

func newPairCode() string {
	var sb strings.Builder
	max := big.NewInt(int64(len(pairAlphabet)))
	for i := 0; i < 6; i++ {
		if i == 3 {
			sb.WriteByte('-')
		}
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			panic("crypto/rand failed: " + err.Error())
		}
		sb.WriteByte(pairAlphabet[n.Int64()])
	}
	return sb.String()
}

// normalizePairCode accepts "k7q4mx", "K7Q 4MX", "k7q-4mx" etc. and returns "K7Q-4MX".
func normalizePairCode(s string) (string, bool) {
	var b []byte
	for _, r := range strings.ToUpper(s) {
		switch {
		case r == '-' || r == ' ' || r == '\t':
			continue
		case r < 128 && strings.IndexByte(pairAlphabet, byte(r)) >= 0:
			b = append(b, byte(r))
		default:
			return "", false
		}
	}
	if len(b) != 6 {
		return "", false
	}
	return string(b[:3]) + "-" + string(b[3:]), true
}

// ---- secrets encryption ----------------------------------------------------

func loadOrCreateKey(path string, logger *log.Logger) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		if len(b) != 32 {
			return nil, fmt.Errorf("%s: expected 32 bytes, found %d (refusing to continue; restore the original key)", path, len(b))
		}
		if fi, err := os.Stat(path); err == nil && fi.Mode().Perm()&0o077 != 0 {
			if err := os.Chmod(path, 0o600); err != nil {
				logger.Printf("warning: %s is readable by others and chmod failed: %v", path, err)
			}
		}
		return b, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read secret key: %w", err)
	}
	key := randBytes(32)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create secret key: %w", err)
	}
	if _, err := f.Write(key); err != nil {
		f.Close()
		return nil, fmt.Errorf("write secret key: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, fmt.Errorf("write secret key: %w", err)
	}
	if err := f.Close(); err != nil {
		return nil, fmt.Errorf("write secret key: %w", err)
	}
	logger.Printf("generated new encryption key at %s (back it up together with the database)", path)
	return key, nil
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

const encPrefix = "enc1:"

// aad binds a ciphertext to its record so ciphertexts cannot be swapped between records/users.
func aad(userID, collection, id string) []byte {
	return []byte(userID + "\x00" + collection + "\x00" + id)
}

func (a *App) encrypt(userID, collection, id string, plain []byte) string {
	nonce := randBytes(a.aead.NonceSize())
	sealed := a.aead.Seal(nonce, nonce, plain, aad(userID, collection, id))
	return encPrefix + base64.StdEncoding.EncodeToString(sealed)
}

func (a *App) decrypt(userID, collection, id, stored string) ([]byte, error) {
	if !strings.HasPrefix(stored, encPrefix) {
		return nil, errors.New("secret record is not encrypted")
	}
	raw, err := base64.StdEncoding.DecodeString(stored[len(encPrefix):])
	if err != nil {
		return nil, err
	}
	ns := a.aead.NonceSize()
	if len(raw) < ns {
		return nil, errors.New("ciphertext too short")
	}
	return a.aead.Open(nil, raw[:ns], raw[ns:], aad(userID, collection, id))
}

// ---- scopes ------------------------------------------------------------------

var allScopes = []string{"read", "write", "secrets"}

var scopeOrder = map[string]int{"read": 0, "write": 1, "secrets": 2}

// normalizeScopes validates, de-duplicates and orders scopes. ok=false on an unknown scope.
func normalizeScopes(in []string) ([]string, bool) {
	seen := map[string]bool{}
	out := []string{}
	for _, s := range in {
		s = strings.ToLower(strings.TrimSpace(s))
		if _, ok := scopeOrder[s]; !ok {
			return nil, false
		}
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	sort.Slice(out, func(i, j int) bool { return scopeOrder[out[i]] < scopeOrder[out[j]] })
	return out, true
}

func splitScopes(s string) []string {
	if s == "" {
		return []string{}
	}
	out, _ := normalizeScopes(strings.Split(s, ","))
	if out == nil {
		return []string{}
	}
	return out
}

func joinScopes(s []string) string { return strings.Join(s, ",") }

// subsetOf reports whether every scope in s is also in of.
func subsetOf(s, of []string) bool {
	for _, x := range s {
		found := false
		for _, y := range of {
			if x == y {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
