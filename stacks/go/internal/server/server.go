// Package server serves the application's HTTP endpoints.
//
// Replace the placeholder page with your own routes. Keep the server answering
// GET / (or move the probes in deploy/deployment.yaml with it): the platform's
// liveness and readiness probes call it.
package server

import (
	"context"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"time"

	"github.com/devantler-tech/app/internal/featureflag"
	"github.com/open-feature/go-sdk/openfeature"
)

const (
	// readHeaderTimeout bounds how long a client may take to send request
	// headers, so a slow client cannot hold a connection open indefinitely.
	readHeaderTimeout = 5 * time.Second
	// shutdownTimeout bounds how long in-flight requests may finish after the
	// process is asked to stop. Keep it below the pod's termination grace period.
	shutdownTimeout = 10 * time.Second
	// pageTitle titles the placeholder page.
	pageTitle = "app"
)

// Handler returns the application's routes. GET / serves a placeholder page
// whose text depends on featureflag.ExampleFlag, to show the both-states pattern.
func Handler(flags *openfeature.Client) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")

		_, _ = io.WriteString(writer, page(featureflag.ExampleFeature(request.Context(), flags)))
	})

	return mux
}

// Run serves handler on addr until ctx is cancelled, then gives in-flight
// requests shutdownTimeout to finish.
func Run(ctx context.Context, addr string, handler http.Handler) error {
	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
	}

	serveErr := make(chan error, 1)

	go func() {
		serveErr <- srv.ListenAndServe()
	}()

	select {
	case err := <-serveErr:
		return fmt.Errorf("serve %s: %w", addr, err)
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
	defer cancel()

	err := srv.Shutdown(shutdownCtx)
	if err != nil {
		return fmt.Errorf("shut down %s: %w", addr, err)
	}

	err = <-serveErr
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve %s: %w", addr, err)
	}

	return nil
}

func page(message string) string {
	return "<!doctype html><title>" + pageTitle + "</title>" +
		"<h1>Replace this placeholder with your app.</h1>" +
		"<p>" + html.EscapeString(message) + "</p>\n"
}
