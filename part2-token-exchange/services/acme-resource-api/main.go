// acme-resource-api is a minimal stand-in for Acme's real customer/billing API.
//
// It plays the same role httpbin played in the original (Enterprise) demo: it's
// the thing at the end of the chain that the exchanged token must satisfy. Two
// things make it a genuine enforcement point rather than a rubber stamp:
//
//  1. It verifies the inbound bearer's RS256 signature itself, against the
//     token-exchange-plugin's own JWKS — it does not just trust the gateway.
//  2. It checks the token's `scope` claim against the operation being called
//     (GET customer / PUT customer / GET orders / POST refund) and returns 403
//     if the narrowed scope from the exchange doesn't cover this action.
//
// The response body echoes the request headers it received (under `headers`),
// the same trick httpbin's /anything endpoint used — that's what lets the chat
// app's "Delegation inspector" show the exchanged token exactly as this API
// saw it, with zero chat-side code changes.
package main

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ---- JWKS fetch + cache (keyed by kid) --------------------------------------

type jwks struct {
	mu     sync.RWMutex
	url    string
	keys   map[string]*rsa.PublicKey
	loaded time.Time
}

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	N   string `json:"n"`
	E   string `json:"e"`
}
type jwkSet struct {
	Keys []jwk `json:"keys"`
}

func newJWKS(url string) *jwks { return &jwks{url: url, keys: map[string]*rsa.PublicKey{}} }

func (j *jwks) refresh() error {
	resp, err := http.Get(j.url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("jwks fetch: HTTP %d", resp.StatusCode)
	}
	var set jwkSet
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return err
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" {
			continue
		}
		nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
		if err != nil {
			continue
		}
		eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
		if err != nil {
			continue
		}
		e := 0
		for _, b := range eBytes {
			e = e<<8 | int(b)
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: e}
	}
	j.mu.Lock()
	j.keys = keys
	j.loaded = time.Now()
	j.mu.Unlock()
	return nil
}

func (j *jwks) keyFor(kid string) (*rsa.PublicKey, error) {
	j.mu.RLock()
	k, ok := j.keys[kid]
	stale := time.Since(j.loaded) > 30*time.Second
	j.mu.RUnlock()
	if !ok || stale {
		if err := j.refresh(); err != nil && !ok {
			return nil, err
		}
		j.mu.RLock()
		k, ok = j.keys[kid]
		j.mu.RUnlock()
		if !ok {
			return nil, fmt.Errorf("unknown kid %q", kid)
		}
	}
	return k, nil
}

// ---- config ------------------------------------------------------------------

var cfg = struct {
	Port        string
	JWKSURL     string
	ExpectedAud string
}{
	Port:        env("PORT", "8181"),
	JWKSURL:     env("JWKS_URL", "http://acme-token-exchange-plugin:8081/.well-known/jwks.json"),
	ExpectedAud: env("EXPECTED_AUD", "api.acme.internal"),
}

var keys = newJWKS(cfg.JWKSURL)

// ---- auth + scope enforcement ------------------------------------------------

// Azp/Scope/Sub are declared explicitly even though RegisteredClaims also has
// Subject, because we read them directly (c.Sub, c.Scope) below; Aud is NOT
// redeclared here — it must come from the embedded RegisteredClaims.Aud (via
// GetAudience()) since a shallower duplicate field would silently shadow it
// during JSON unmarshal and GetAudience() would always return empty.
type claims struct {
	Sub   string `json:"sub"`
	Azp   string `json:"azp"`
	Scope string `json:"scope"`
	jwt.RegisteredClaims
}

// authorize verifies the bearer's signature/exp/aud and returns its claims, or
// an HTTP status + message to send back if verification fails.
func authorize(r *http.Request) (*claims, int, string) {
	h := r.Header.Get("Authorization")
	if h == "" || !strings.HasPrefix(h, "Bearer ") {
		return nil, http.StatusUnauthorized, "missing bearer token"
	}
	raw := strings.TrimPrefix(h, "Bearer ")

	var c claims
	_, err := jwt.ParseWithClaims(raw, &c, func(t *jwt.Token) (interface{}, error) {
		kid, _ := t.Header["kid"].(string)
		return keys.keyFor(kid)
	}, jwt.WithValidMethods([]string{"RS256"}))
	if err != nil {
		return nil, http.StatusUnauthorized, "invalid token: " + err.Error()
	}

	auds, _ := c.GetAudience()
	audOK := false
	for _, a := range auds {
		if a == cfg.ExpectedAud {
			audOK = true
		}
	}
	if !audOK {
		return nil, http.StatusForbidden, fmt.Sprintf("token audience %v does not include %q", auds, cfg.ExpectedAud)
	}
	return &c, 0, ""
}

func hasScope(c *claims, required string) bool {
	for _, s := range strings.Fields(c.Scope) {
		if s == required {
			return true
		}
	}
	return false
}

func requireScope(w http.ResponseWriter, r *http.Request, bodyBytes []byte, required string) (*claims, bool) {
	c, status, msg := authorize(r)
	if status != 0 {
		writeEcho(w, r, bodyBytes, status, map[string]any{"error": msg})
		return nil, false
	}
	if !hasScope(c, required) {
		w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer error="insufficient_scope", scope=%q`, required))
		writeEcho(w, r, bodyBytes, http.StatusForbidden, map[string]any{
			"error":           "insufficient_scope",
			"required_scope":  required,
			"token_scope":     c.Scope,
			"token_sub":       c.Sub,
			"token_azp":       c.Azp,
		})
		return nil, false
	}
	return c, true
}

// ---- httpbin-style echo response --------------------------------------------

// writeEcho mimics httpbin's /anything shape closely enough for the chat app's
// extractUpstreamToken to keep working unmodified: a top-level "headers" object
// with the request headers this API actually received (in particular, the
// already-exchanged Authorization). bodyBytes is whatever the caller already
// read from r.Body (read once, up front, by each handler — r.Body is a
// single-read stream, so re-reading it here would always come up empty).
func writeEcho(w http.ResponseWriter, r *http.Request, bodyBytes []byte, status int, extra map[string]any) {
	headers := map[string]string{}
	for k, v := range r.Header {
		if len(v) > 0 {
			headers[k] = v[0]
		}
	}
	var body any
	if len(bodyBytes) > 0 {
		var parsed any
		if json.Unmarshal(bodyBytes, &parsed) == nil {
			body = parsed
		}
	}
	out := map[string]any{
		"method":  r.Method,
		"url":     r.URL.String(),
		"headers": headers,
		"json":    body,
	}
	for k, v := range extra {
		out[k] = v
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(out)
}

// ---- synthetic Acme data ------------------------------------------------------

type customer struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Plan  string `json:"plan"`
}

var customers = map[string]*customer{
	"C-1024": {"C-1024", "Priya N.", "priya@acme.example", "Pro"},
	"C-2048": {"C-2048", "Sam K.", "sam@acme.example", "Business"},
}
var customersMu sync.Mutex

var orders = map[string][]map[string]any{
	"C-1024": {
		{"order_id": "O-9001", "item": "Acme Widget Pro", "amount": 49.99, "status": "delivered"},
		{"order_id": "O-9002", "item": "Acme Widget Pro (renewal)", "amount": 49.99, "status": "delivered"},
	},
	"C-2048": {
		{"order_id": "O-9101", "item": "Acme Enterprise Bundle", "amount": 499.00, "status": "delivered"},
	},
}

func lookupOrDefault(id string) *customer {
	if c, ok := customers[id]; ok {
		return c
	}
	return &customer{ID: id, Name: "Unknown customer", Email: "", Plan: "n/a"}
}

var customerPath = regexp.MustCompile(`^/anything/customers/([^/]+)$`)
var ordersPath = regexp.MustCompile(`^/anything/customers/([^/]+)/orders$`)

func handleCustomer(w http.ResponseWriter, r *http.Request, id string) {
	body, _ := io.ReadAll(r.Body)
	switch r.Method {
	case http.MethodGet:
		if _, ok := requireScope(w, r, body, "customers:read"); !ok {
			return
		}
		writeEcho(w, r, body, http.StatusOK, map[string]any{"acme": map[string]any{"action": "lookup_customer", "customer": lookupOrDefault(id)}})
	case http.MethodPut:
		if _, ok := requireScope(w, r, body, "customers:write"); !ok {
			return
		}
		var parsed struct {
			Email string `json:"email"`
		}
		_ = json.Unmarshal(body, &parsed)
		customersMu.Lock()
		cust := lookupOrDefault(id)
		if parsed.Email != "" {
			cust.Email = parsed.Email
		}
		customers[id] = cust
		customersMu.Unlock()
		writeEcho(w, r, body, http.StatusOK, map[string]any{"acme": map[string]any{"action": "update_customer", "customer": cust}})
	default:
		http.NotFound(w, r)
	}
}

func handleOrders(w http.ResponseWriter, r *http.Request, id string) {
	body, _ := io.ReadAll(r.Body)
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	if _, ok := requireScope(w, r, body, "customers:read"); !ok {
		return
	}
	writeEcho(w, r, body, http.StatusOK, map[string]any{"acme": map[string]any{"action": "recent_orders", "customer_id": id, "orders": orders[id]}})
}

func handleRefund(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	body, _ := io.ReadAll(r.Body)
	var parsed struct {
		CustomerID string  `json:"customer_id"`
		Amount     float64 `json:"amount"`
	}
	_ = json.Unmarshal(body, &parsed)
	if _, ok := requireScope(w, r, body, "refunds:write"); !ok {
		return
	}
	refundID := fmt.Sprintf("R-%d", time.Now().UnixNano()%1_000_000)
	writeEcho(w, r, body, http.StatusOK, map[string]any{"acme": map[string]any{
		"action": "issue_refund", "refund_id": refundID, "status": "issued",
		"customer_id": parsed.CustomerID, "amount": parsed.Amount,
	}})
}

func main() {
	go func() {
		if err := keys.refresh(); err != nil {
			log.Printf("initial JWKS fetch failed (will retry lazily): %v", err)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"status":"healthy"}`)
	})
	mux.HandleFunc("/anything/refunds", handleRefund)
	mux.HandleFunc("/anything/customers/", func(w http.ResponseWriter, r *http.Request) {
		if m := ordersPath.FindStringSubmatch(r.URL.Path); m != nil {
			handleOrders(w, r, m[1])
			return
		}
		if m := customerPath.FindStringSubmatch(r.URL.Path); m != nil {
			handleCustomer(w, r, m[1])
			return
		}
		http.NotFound(w, r)
	})

	log.Printf("acme-resource-api listening on :%s (JWKS %s, aud %s)", cfg.Port, cfg.JWKSURL, cfg.ExpectedAud)
	log.Fatal(http.ListenAndServe(":"+cfg.Port, mux))
}
