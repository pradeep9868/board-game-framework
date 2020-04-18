package main

import (
	"fmt"
	"math/rand"
	"net/http"
	"time"
)

type Client struct {
	id string
}

// NewClient creates a new client proxy from an incoming request
func NewClient(r *http.Request) Client {
	clientID := clientID(r.Cookies())
	if clientID == "" {
		clientID = newClientID()
	}

	return Client{
		id: clientID,
	}
}

// newClientID generates a random clientID string
func newClientID() string {
	part1 := time.Now().UnixNano()
	part2 := rand.Int63()
	return fmt.Sprintf("%d.%d", part1, part2)
}

// clientID returns the contents of the clientID cookie, or empty string
// if there's none there
func clientID(cookies []*http.Cookie) string {
	for _, cookie := range cookies {
		if cookie.Name == "clientID" {
			return cookie.Value
		}
	}

	return ""
}
