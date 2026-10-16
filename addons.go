package app

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"
)

// ---- addon URL normalisation ------------------------------------------------------------
//
// An addon's sync record id is its manifest (transport) URL, so the server must produce
// exactly the string both apps produce for the same input:
//
//   - iOS (AddonManager.normalize + InstalledAddon.manifestURL): trim, "stremio://" → "https://",
//     prefix "https://" when there is no scheme, URL(string:) percent-encodes characters that
//     aren't legal in a URL (e.g. "|"), then base (without "manifest.json", trailing slashes
//     trimmed) + "/manifest.json".
//   - Android (Addons.normalize + Addons.manifestUrl/canonicalUrl): the same steps; illegal
//     characters are percent-encoded as UTF-8 with upper-case hex, keeping ASCII letters/digits
//     and -._~!$&'()*+,;=:@/?#%[] as they are.

const addonURLSafe = "-._~!$&'()*+,;=:@/?#%[]"

// canonicalURL percent-encodes every byte that is not an ASCII letter/digit or URL-safe
// punctuation (mirrors Addons.canonicalUrl on Android).
func canonicalURL(s string) string {
	var sb strings.Builder
	sb.Grow(len(s) + 8)
	for _, r := range s {
		if r < 128 && (r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune(addonURLSafe, r)) {
			sb.WriteRune(r)
			continue
		}
		var buf [utf8.UTFMax]byte
		n := utf8.EncodeRune(buf[:], r) // invalid input bytes arrive as U+FFFD, like the clients
		for _, b := range buf[:n] {
			fmt.Fprintf(&sb, "%%%02X", b)
		}
	}
	return sb.String()
}

var errBadAddonURL = errors.New("enter an addon manifest URL (https://…/manifest.json or stremio://…)")

// normalizeAddonURL turns what an admin typed into the canonical transport URL.
func normalizeAddonURL(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", errBadAddonURL
	}
	if strings.HasPrefix(strings.ToLower(s), "stremio://") {
		s = "https://" + s[len("stremio://"):]
	}
	if !strings.Contains(s, "://") {
		s = "https://" + s
	}
	s = strings.TrimRight(s, "/")
	s = strings.TrimSuffix(s, "/manifest.json")
	s = strings.TrimRight(s, "/")
	out := canonicalURL(s + "/manifest.json")
	u, err := url.Parse(out)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || len(out) > 2048 {
		return "", errBadAddonURL
	}
	return out, nil
}

// ---- manifest fetch ---------------------------------------------------------------------

type addonManifest struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Version       string `json:"version"`
	Description   string `json:"description"`
	Logo          string `json:"logo"`
	BehaviorHints struct {
		ConfigurationRequired bool `json:"configurationRequired"`
	} `json:"behaviorHints"`
}

const (
	manifestTimeout = 5 * time.Second
	maxManifestBody = 1 << 20
	maxLogoBytes    = 200 << 10
)

var logoTypes = map[string]bool{
	"image/png": true, "image/jpeg": true, "image/gif": true, "image/webp": true, "image/svg+xml": true,
}

// fetchManifest downloads an addon manifest with a short timeout. The logo (if any) is
// downloaded too and returned as a data: URI so the web admin can show it under its strict CSP.
func (a *App) fetchManifest(ctx context.Context, transportURL string) (addonManifest, string, error) {
	var m addonManifest
	ctx, cancel := context.WithTimeout(ctx, manifestTimeout)
	defer cancel()
	body, _, err := a.httpGet(ctx, transportURL, maxManifestBody)
	if err != nil {
		return m, "", err
	}
	if err := json.Unmarshal(body, &m); err != nil {
		return m, "", errors.New("the URL did not return an addon manifest")
	}
	if m.ID == "" && m.Name == "" {
		return m, "", errors.New("the URL did not return an addon manifest")
	}
	m.Name = cleanText(m.Name, 100)
	m.ID = cleanText(m.ID, 200)
	m.Version = cleanText(m.Version, 40)
	m.Description = cleanText(m.Description, 500)
	logo := ""
	if m.Logo != "" {
		if base, err := url.Parse(transportURL); err == nil {
			if lu, err := base.Parse(m.Logo); err == nil && (lu.Scheme == "https" || lu.Scheme == "http") {
				lctx, lcancel := context.WithTimeout(context.Background(), manifestTimeout)
				data, ctype, err := a.httpGet(lctx, lu.String(), maxLogoBytes)
				lcancel()
				if err == nil {
					mt, _, _ := mime.ParseMediaType(ctype)
					if logoTypes[mt] {
						logo = "data:" + mt + ";base64," + base64.StdEncoding.EncodeToString(data)
					}
				}
			}
		}
	}
	return m, logo, nil
}

func (a *App) httpGet(ctx context.Context, u string, max int64) ([]byte, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("Accept", "application/json, image/*;q=0.8, */*;q=0.5")
	req.Header.Set("User-Agent", "StreamForgeSync/"+a.cfg.Version)
	res, err := a.httpClient.Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, "", errors.New("timed out fetching the manifest")
		}
		return nil, "", errors.New("could not reach the addon")
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("the addon answered HTTP %d", res.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, max+1))
	if err != nil {
		return nil, "", errors.New("could not read the addon's response")
	}
	if int64(len(b)) > max {
		return nil, "", errors.New("response too large")
	}
	return b, res.Header.Get("Content-Type"), nil
}
