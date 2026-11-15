package server_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/devantler-tech/app/internal/featureflag"
	"github.com/devantler-tech/app/internal/server"
)

type handlerCase struct {
	name     string
	flagOn   bool
	path     string
	wantCode int
	wantBody string
}

func TestHandler(t *testing.T) {
	t.Parallel()

	testCases := []handlerCase{
		{
			name:     "root serves the default path",
			flagOn:   false,
			path:     "/",
			wantCode: http.StatusOK,
			wantBody: "default output",
		},
		{
			name:     "root serves the flagged path",
			flagOn:   true,
			path:     "/",
			wantCode: http.StatusOK,
			wantBody: "new feature output",
		},
		{
			name:     "unknown path is not found",
			flagOn:   false,
			path:     "/missing",
			wantCode: http.StatusNotFound,
			wantBody: "",
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			assertResponse(t, testCase)
		})
	}
}

func TestRunStopsWhenContextIsCancelled(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(t.Context())
	cancel()

	err := server.Run(ctx, "127.0.0.1:0", http.NotFoundHandler())
	if err != nil {
		t.Fatalf("run: %v", err)
	}
}

func assertResponse(t *testing.T, testCase handlerCase) {
	t.Helper()

	flags, err := featureflag.NewClient(
		"server-test-"+testCase.name,
		featureflag.NewProvider(map[string]bool{featureflag.ExampleFlag: testCase.flagOn}),
	)
	if err != nil {
		t.Fatalf("new client: %v", err)
	}

	request := httptest.NewRequestWithContext(t.Context(), http.MethodGet, testCase.path, nil)
	recorder := httptest.NewRecorder()

	server.Handler(flags).ServeHTTP(recorder, request)

	if recorder.Code != testCase.wantCode {
		t.Fatalf("status = %d, want %d", recorder.Code, testCase.wantCode)
	}

	body := recorder.Body.String()
	if !strings.Contains(body, testCase.wantBody) {
		t.Fatalf("body = %q, want it to contain %q", body, testCase.wantBody)
	}
}
