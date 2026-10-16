package app

import (
	"errors"
	"sync"
	"time"
)

// Pairings live in memory only: they are short-lived (10 min), and keeping them out of the
// database means a freshly minted token is never written to disk. A restart simply makes
// the TV start over.
type pairing struct {
	id       string
	code     string
	name     string
	platform string
	ip       string
	created  time.Time
	expires  time.Time
	approved bool
	token    string
	user     User
	device   Device
}

type pairStore struct {
	mu     sync.Mutex
	byID   map[string]*pairing
	byCode map[string]*pairing
}

const maxPendingPairings = 1000

func newPairStore() *pairStore {
	return &pairStore{byID: map[string]*pairing{}, byCode: map[string]*pairing{}}
}

func (s *pairStore) start(name, platform, ip string, now, expires time.Time) (*pairing, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cleanupLocked(now)
	if len(s.byID) >= maxPendingPairings {
		return nil, errors.New("too many pending pairings, try again in a few minutes")
	}
	var code string
	for i := 0; ; i++ {
		code = newPairCode()
		if _, taken := s.byCode[code]; !taken {
			break
		}
		if i > 50 {
			return nil, errors.New("could not allocate a pairing code")
		}
	}
	p := &pairing{
		id: "p_" + hashToken(string(randBytes(32)))[:32], code: code,
		name: name, platform: platform, ip: ip, created: now, expires: expires,
	}
	s.byID[p.id] = p
	s.byCode[p.code] = p
	return p, nil
}

type pollResult struct {
	status string // pending | approved | gone
	token  string
	user   User
	device Device
}

// poll returns the pairing state. An approved pairing hands out its token exactly once.
func (s *pairStore) poll(id string, now time.Time) pollResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.byID[id]
	if !ok {
		return pollResult{status: "gone"}
	}
	if p.approved {
		s.removeLocked(p)
		d := p.device
		d.Current = true
		return pollResult{status: "approved", token: p.token, user: p.user, device: d}
	}
	if !now.Before(p.expires) {
		s.removeLocked(p)
		return pollResult{status: "gone"}
	}
	return pollResult{status: "pending"}
}

// approve finds a pending pairing by code and creates its device via create (under the lock,
// so a code can only be approved once). status is "ok", "not_found", "expired" or "used".
func (s *pairStore) approve(code string, now time.Time, create func(*pairing) (Device, string, error), user User) (Device, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.byCode[code]
	if !ok {
		return Device{}, "not_found", nil
	}
	if p.approved {
		return Device{}, "used", nil
	}
	if !now.Before(p.expires) {
		s.removeLocked(p)
		return Device{}, "expired", nil
	}
	d, token, err := create(p)
	if err != nil {
		return Device{}, "", err
	}
	p.approved = true
	p.token = token
	p.user = user
	p.device = d
	// Give the TV a little longer than the original window to pick the token up.
	if p.expires.Sub(now) < 2*time.Minute {
		p.expires = now.Add(2 * time.Minute)
	}
	return d, "ok", nil
}

func (s *pairStore) removeLocked(p *pairing) {
	delete(s.byID, p.id)
	if s.byCode[p.code] == p {
		delete(s.byCode, p.code)
	}
}

func (s *pairStore) cleanupLocked(now time.Time) {
	for _, p := range s.byID {
		if !now.Before(p.expires) {
			s.removeLocked(p)
		}
	}
}

func (s *pairStore) cleanup(now time.Time) {
	s.mu.Lock()
	s.cleanupLocked(now)
	s.mu.Unlock()
}
