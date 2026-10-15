package app

import (
	"testing"
	"time"
)

type dismissedView struct {
	Collection  string `json:"collection"`
	ID          string `json:"id"`
	Name        string `json:"name"`
	DismissedAt int64  `json:"dismissedAt"`
}

func (e *testEnv) dismissedOf(adminToken, userID string) []dismissedView {
	e.t.Helper()
	var d struct {
		Dismissed []dismissedView `json:"dismissed"`
	}
	e.expect(e.do("GET", "/api/admin/users/"+userID, adminToken, nil), 200).json(e.t, &d)
	return d.Dismissed
}

func dismissal(collection, id string, ts int64, deleted bool) rec {
	r := rec{"collection": dismissedCollection, "id": collection + "|" + id, "updatedAt": ts}
	if deleted {
		r["deleted"] = true
	} else {
		r["data"] = rec{"collection": collection, "id": id, "dismissedAt": ts}
	}
	return r
}

func TestMemberDismissal(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	ms := manifestServer(t, "Torrentio")
	member := e.createUser(admin.Token, "mo", nil)
	phone := e.login("mo", "password-mo", "ios")
	tv := e.login("mo", "password-mo", "androidtv")

	addon := e.createAddon(admin.Token, map[string]any{"url": ms.URL, "users": []string{member.ID}})
	tu := addon.TransportURL
	conn := e.createConnection(admin.Token, "Home", "http://dispatcharr.lan")
	e.expect(e.do("PUT", "/api/admin/dispatcharr/"+conn.ID+"/users/"+member.ID, admin.Token, map[string]any{"authMode": "xc", "username": "u", "xcPassword": "p"}), 200)
	e.expect(e.do("PUT", "/api/admin/users/"+member.ID+"/settings", admin.Token, map[string]any{"values": map[string]any{"seekStep": 30}}), 200)

	p := e.pull(phone.Token, "since=0")
	if findRec(p, "addons", tu) == nil || findRec(p, "servers", conn.ID) == nil || findRec(p, "settings", "seekStep") == nil {
		t.Fatalf("initial pull: %+v", p)
	}
	now := time.Now().UnixMilli()

	// "Continue without it": dismissal + tombstones in one push (tombstone first, order doesn't matter).
	_, res := e.push(phone.Token,
		rec{"collection": "addons", "id": tu, "deleted": true, "updatedAt": now},
		dismissal("addons", tu, now, false),
		dismissal("servers", conn.ID, now, false),
		rec{"collection": "servers", "id": conn.ID, "deleted": true, "updatedAt": now},
		dismissal("settings", "seekStep", now, false),
		rec{"collection": "settings", "id": "seekStep", "data": rec{"value": 5}, "updatedAt": now},
	)
	for _, r := range res {
		if r.Status != "applied" {
			t.Fatalf("dismissal push: %+v", res)
		}
	}
	// The other device of the user sees the removal, the secret's tombstone, the dismissals
	// and the member's own setting value.
	tp := e.pull(tv.Token, "since=0")
	if r := findRec(tp, "addons", tu); r == nil || !r.Deleted || r.Managed {
		t.Fatalf("addon not removed for the user: %+v", r)
	}
	if r := findRec(tp, "servers", conn.ID); r == nil || !r.Deleted {
		t.Fatalf("server not removed: %+v", r)
	}
	if r := findRec(tp, "secrets", "server:"+conn.ID); r == nil || !r.Deleted || string(r.Data) != "null" {
		t.Fatalf("secret of a dismissed server must be tombstoned: %+v", r)
	}
	if r := findRec(tp, "settings", "seekStep"); r == nil || r.Managed || string(r.Data) != `{"value":5}` {
		t.Fatalf("dismissed setting should be the member's own value: %+v", r)
	}
	for _, id := range []string{"addons|" + tu, "servers|" + conn.ID, "settings|seekStep"} {
		if r := findRec(tp, dismissedCollection, id); r == nil || r.Deleted {
			t.Fatalf("dismissal %s not synced: %+v", id, tp)
		}
	}

	// Reconcile (any admin change) doesn't bring them back.
	e.expect(e.do("PATCH", "/api/admin/addons/"+addon.ID, admin.Token, map[string]any{"name": "Torrentio 2"}), 200)
	e.expect(e.do("PATCH", "/api/admin/dispatcharr/"+conn.ID, admin.Token, map[string]any{"name": "Home 2"}), 200)
	if n, err := e.app.reconcileUser(member.ID); err != nil || n != 0 {
		t.Fatalf("reconcile after dismissal wrote %d records (%v)", n, err)
	}
	p2 := e.pull(phone.Token, "since="+itoa(tp.Rev))
	for _, k := range [][2]string{{"addons", tu}, {"servers", conn.ID}, {"secrets", "server:" + conn.ID}, {"settings", "seekStep"}} {
		if r := findRec(p2, k[0], k[1]); r != nil {
			t.Fatalf("dismissed %v came back: %+v", k, r)
		}
	}
	// The setting is the member's: a later change is applied.
	if _, res := e.push(phone.Token, rec{"collection": "settings", "id": "seekStep", "data": rec{"value": 7}, "updatedAt": now + 10}); res[0].Status != "applied" {
		t.Fatalf("own setting after dismissal: %+v", res)
	}

	// Without a dismissal a member's delete is still refused (stale + restamp).
	e.expect(e.do("PUT", "/api/admin/users/"+member.ID+"/settings", admin.Token, map[string]any{"values": map[string]any{"autoplayNext": false}}), 200)
	ap := e.pull(phone.Token, "since=0")
	ar := findRec(ap, "settings", "autoplayNext")
	if _, res := e.push(phone.Token, rec{"collection": "settings", "id": "autoplayNext", "data": rec{"value": true}, "updatedAt": ar.UpdatedAt + 1}); res[0].Status != "stale" {
		t.Fatalf("undismissed managed edit should stay protected: %+v", res)
	}

	// Admin page lists them.
	dv := e.dismissedOf(admin.Token, member.ID)
	if len(dv) != 3 {
		t.Fatalf("dismissed view: %+v", dv)
	}
	names := map[string]string{}
	for _, x := range dv {
		names[x.Collection] = x.Name
		if x.DismissedAt != now {
			t.Fatalf("dismissedAt: %+v", x)
		}
	}
	if names["addons"] != "Torrentio 2" || names["servers"] != "Home 2" || names["settings"] != "Seek step (seconds)" {
		t.Fatalf("dismissed names: %+v", names)
	}

	// "Restore from sync" on the TV: tombstone of the dismissal → the addon is re-added with a new rev.
	before := e.pull(phone.Token, "since=0").Rev
	_, res = e.push(tv.Token, dismissal("addons", tu, now+20, true))
	if res[0].Status != "applied" {
		t.Fatalf("restore push: %+v", res)
	}
	p3 := e.pull(phone.Token, "since="+itoa(before))
	if r := findRec(p3, "addons", tu); r == nil || r.Deleted || !r.Managed || r.Rev <= before || dataMap(t, r)["name"] != "Torrentio 2" {
		t.Fatalf("restore didn't re-add the addon: %+v", p3)
	}

	// Admin "Push again" for the server clears the dismissal and re-adds server + credentials.
	e.expect(e.do("POST", "/api/admin/users/"+member.ID+"/dismissed/restore", admin.Token, map[string]any{"collection": "servers", "id": conn.ID}), 204)
	p4 := e.pull(phone.Token, "since="+itoa(p3.Rev))
	if r := findRec(p4, "servers", conn.ID); r == nil || r.Deleted || !r.Managed {
		t.Fatalf("push again: server %+v", p4)
	}
	if r := findRec(p4, "secrets", "server:"+conn.ID); r == nil || r.Deleted || string(r.Data) != `{"xcPassword":"p","webPassword":"","apiKey":""}` {
		t.Fatalf("push again: secret %+v", p4)
	}
	if r := findRec(p4, dismissedCollection, "servers|"+conn.ID); r == nil || !r.Deleted {
		t.Fatalf("push again: dismissal not tombstoned %+v", p4)
	}
	e.expect(e.do("POST", "/api/admin/users/"+member.ID+"/dismissed/restore", admin.Token, map[string]any{"collection": "servers", "id": conn.ID}), 404)
	e.expect(e.do("POST", "/api/admin/users/"+member.ID+"/dismissed/restore", admin.Token, map[string]any{"collection": "secrets", "id": "server:" + conn.ID}), 400)
	e.expect(e.do("POST", "/api/admin/users/"+member.ID+"/dismissed/restore", phone.Token, map[string]any{"collection": "settings", "id": "seekStep"}), 403)

	// Setting a managed value for the user again overrides the setting's dismissal.
	e.expect(e.do("PUT", "/api/admin/users/"+member.ID+"/settings", admin.Token, map[string]any{"values": map[string]any{"seekStep": 45}}), 200)
	if r := findRec(e.pull(phone.Token, "since="+itoa(p4.Rev)), "settings", "seekStep"); r == nil || !r.Managed || string(r.Data) != `{"value":45,"managed":true}` {
		t.Fatalf("re-managed setting: %+v", r)
	}
	if dv := e.dismissedOf(admin.Token, member.ID); len(dv) != 0 {
		t.Fatalf("dismissals left: %+v", dv)
	}

	// Unassigning a dismissed item drops the dismissal, so a later assignment reaches the user.
	pre := e.pull(phone.Token, "since=0").Rev
	e.push(phone.Token, dismissal("addons", tu, now+30, false), rec{"collection": "addons", "id": tu, "deleted": true, "updatedAt": now + 30})
	e.expect(e.do("DELETE", "/api/admin/addons/"+addon.ID+"/users/"+member.ID, admin.Token, nil), 204)
	if r := findRec(e.pull(phone.Token, "since="+itoa(pre)), dismissedCollection, "addons|"+tu); r == nil || !r.Deleted {
		t.Fatalf("dismissal of an unassigned item should be dropped: %+v", r)
	}
	e.expect(e.do("PUT", "/api/admin/addons/"+addon.ID+"/users/"+member.ID, admin.Token, nil), 204)
	if r := findRec(e.pull(phone.Token, "since="+itoa(pre)), "addons", tu); r == nil || r.Deleted || !r.Managed {
		t.Fatalf("re-assigned addon: %+v", r)
	}

	// A dismissal on its own (e.g. the item's tombstone was stale) still removes the item.
	pre = e.pull(phone.Token, "since=0").Rev
	e.push(phone.Token, dismissal("addons", tu, time.Now().UnixMilli()+1000, false))
	if r := findRec(e.pull(phone.Token, "since="+itoa(pre)), "addons", tu); r == nil || !r.Deleted {
		t.Fatalf("dismissal alone should tombstone the addon: %+v", r)
	}

	// Another user's dismissal doesn't affect anyone else; admins keep full control.
	ad := e.pull(admin.Token, "since=0")
	if r := findRec(ad, dismissedCollection, "addons|"+tu); r != nil {
		t.Fatal("dismissals are per user")
	}
}
