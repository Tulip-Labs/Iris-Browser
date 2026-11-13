package core

import (
	"testing"
	"time"
)

func TestRisk(t *testing.T) {
	unsafe := []string{
		"https://paypal.com.account-check.xyz/login",
		"https://secure-paypal.net/",
		"https://login.microsoft.verify-user.info/",
		"https://user@evil.example.com/",
		"http://203.0.113.9/admin",
		"https://xn--pple-43d.com/",
		"https://github.account-recovery.co/",
	}
	for _, u := range unsafe {
		if Risk(u) == "" {
			t.Errorf("%s should look unsafe", u)
		}
	}
	safe := []string{
		"https://www.paypal.com/signin",
		"https://accounts.google.com/",
		"https://www.google.com.co/search?q=x",
		"https://google.es/",
		"https://login.microsoftonline.com/",
		"https://mail.google.com/",
		"https://docs.github.com/en",
		"https://raw.githubusercontent.com/a/b",
		"https://www.googleapis.com/",
		"http://192.168.1.1/",
		"http://localhost:8080/",
		"https://pineapple.com/",
		"https://es.wikipedia.org/wiki/PayPal",
		"https://example.com/paypal/google",
		"about:blank",
	}
	for _, u := range safe {
		if why := Risk(u); why != "" {
			t.Errorf("%s should not be stopped: %s", u, why)
		}
	}
}

func TestSiteScan(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	dir := t.TempDir()
	s := OpenSiteScan(dir)
	s.now = func() time.Time { return now }
	const u = "https://www.example.com/a"
	if !s.Need(u) {
		t.Fatal("unknown site must be scanned")
	}
	s.Record(u, 0)
	s.Record(u, 0)
	if !s.Need(u) {
		t.Fatal("two clean scans are not enough")
	}
	s.Record("https://example.com/other", 0) // same site, with or without www
	if s.Need(u) {
		t.Fatal("three clean scans: standby")
	}
	if st, _ := s.State(u); st != ScanStandby {
		t.Fatalf("state %d", st)
	}
	for i := 0; i < scanVisits; i++ {
		s.Visit(u)
	}
	if !s.Need(u) {
		t.Fatal("after many visits the site is scanned again")
	}
	s.Record(u, 0)
	if s.Need(u) {
		t.Fatal("still clean")
	}
	now = now.Add(scanAge + time.Hour)
	if !s.Need(u) {
		t.Fatal("an old scan must be repeated")
	}
	s.Record(u, 4) // it now carries ads
	if st, n := s.State(u); st != ScanActive || n != 4 || !s.Need(u) {
		t.Fatalf("a site with ads stays checked: state %d found %d", st, n)
	}
	s.Record(u, 0)
	if !s.Need(u) {
		t.Fatal("one clean scan after ads does not make a site clean")
	}
	s.Flush()
	back := OpenSiteScan(dir)
	if n, _ := back.Counts(); n != 1 {
		t.Fatalf("sites kept on disk: %d", n)
	}
	back.Forget(u)
	if st, _ := back.State(u); st != ScanNew {
		t.Fatal("Forget should drop the site")
	}
	if !s.Need("") || !s.Need("about:blank") {
		t.Fatal("no site: always checked")
	}
}

func TestPlanBudget(t *testing.T) {
	for _, c := range []struct {
		mb      int
		profile string
	}{{4096, "balanced"}, {8192, "balanced"}, {8192, "saver"}, {16384, "speed"}, {0, "balanced"}} {
		p := Plan(c.mb, c.profile)
		if p.LimitMB < 768 || p.LimitMB > 6144 {
			t.Errorf("%+v: page cap %d", c, p.LimitMB)
		}
		if c.mb > 0 && (p.BudgetMB <= 0 || p.BudgetMB >= c.mb || p.ReserveMB <= 0) {
			t.Errorf("%+v: budget %d reserve %d", c, p.BudgetMB, p.ReserveMB)
		}
	}
	if Plan(8192, "saver").LimitMB >= Plan(8192, "speed").LimitMB {
		t.Error("saver must cap a page lower than speed")
	}
}
