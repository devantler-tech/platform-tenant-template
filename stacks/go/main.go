// Package main starts the application's HTTP server.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/devantler-tech/app/internal/featureflag"
	"github.com/devantler-tech/app/internal/server"
)

const (
	// defaultPort is the port the server listens on when PORT is unset. It matches
	// the containerPort and probes in deploy/deployment.yaml.
	defaultPort = "3000"
	// flagDomain names this application's feature-flag client.
	flagDomain = "app"
)

func main() {
	err := run()
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)

		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	flags, err := featureflag.NewClient(flagDomain, featureflag.NewProvider(nil))
	if err != nil {
		return fmt.Errorf("start feature flags: %w", err)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = defaultPort
	}

	err = server.Run(ctx, ":"+port, server.Handler(flags))
	if err != nil {
		return fmt.Errorf("run server: %w", err)
	}

	return nil
}
