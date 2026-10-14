// Command streamforge-sync is the self-hosted StreamForge sync server.
//
// Build: go build -ldflags "-s -w -X main.version=1.2.3" -o streamforge-sync .
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/mohamedt1996/StreamForge/server/internal/app"
)

var version = "dev"

func main() {
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "StreamForge Sync %s\n\nUsage:\n  streamforge-sync            run the server\n  streamforge-sync healthcheck  exit 0 if the local server answers /healthz\n\nConfiguration is read from STREAMFORGE_* environment variables (see README.md).\n", version)
		flag.PrintDefaults()
	}
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	addr := env("STREAMFORGE_ADDR", ":8484")
	if flag.Arg(0) == "healthcheck" {
		os.Exit(healthcheck(addr))
	}

	logger := log.New(os.Stderr, "", log.LstdFlags)
	cfg := app.Config{
		Addr:          addr,
		DataDir:       env("STREAMFORGE_DATA", "/data"),
		Name:          env("STREAMFORGE_NAME", "StreamForge Sync"),
		Version:       version,
		AdminUser:     os.Getenv("STREAMFORGE_ADMIN_USER"),
		AdminPassword: os.Getenv("STREAMFORGE_ADMIN_PASSWORD"),
		OpenSignup:    envBool("STREAMFORGE_OPEN_SIGNUP"),
		TrustProxy:    envBool("STREAMFORGE_TRUST_PROXY"),
		Logger:        logger,
	}
	a, err := app.New(cfg)
	if err != nil {
		logger.Fatalf("startup failed: %v", err)
	}

	// Cancelled on shutdown so held long polls end promptly.
	baseCtx, cancelBase := context.WithCancel(context.Background())
	srv := &http.Server{
		Addr:              addr,
		Handler:           a.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      75 * time.Second, // long polls hold up to 55 s
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 << 10,
		BaseContext:       func(net.Listener) context.Context { return baseCtx },
		ErrorLog:          logger,
	}

	errc := make(chan error, 1)
	go func() {
		logger.Printf("StreamForge Sync %s listening on %s (data: %s)", version, addr, cfg.DataDir)
		errc <- srv.ListenAndServe()
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errc:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Fatalf("server: %v", err)
		}
	case s := <-sig:
		logger.Printf("received %s, shutting down", s)
	}
	cancelBase()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		logger.Printf("shutdown: %v", err)
	}
	if err := a.Close(); err != nil {
		logger.Printf("close: %v", err)
	}
}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envBool(key string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// healthcheck lets the distroless image run a HEALTHCHECK without curl/wget.
func healthcheck(addr string) int {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad STREAMFORGE_ADDR:", err)
		return 1
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	c := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}
	resp, err := c.Get("http://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintln(os.Stderr, "status", resp.Status)
		return 1
	}
	return 0
}
