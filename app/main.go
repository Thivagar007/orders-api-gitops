package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	version := getenv("APP_VERSION", "dev")
	env := getenv("APP_ENV", "local")

	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"service":     "orders-api",
			"version":     version,
			"environment": env,
			"message":     "Hello from orders-api",
		})
	})

	// Liveness: the process is alive.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// Readiness: the app can serve traffic.
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	})

	addr := ":" + getenv("PORT", "8080")
	log.Printf("orders-api %s (%s) listening on %s", version, env, addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
