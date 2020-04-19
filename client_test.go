// Copyright 2020 Nik Silver
//
// Licensed under the GPL v3.0. See file LICENCE.txt for details.

package main

import (
	"testing"
)

func TestWSClient_CreatesNewID(t *testing.T) {
	_, resp, closeFunc, err := wsServerConn(echoHandler)
	defer closeFunc()
	if err != nil {
		t.Fatal(err)
	}

	cookies := resp.Cookies()
	clientID := clientID(cookies)
	if clientID == "" {
		t.Errorf("clientID cookie is empty or not defined")
	}
}

func TestWSClient_ReusesOldId(t *testing.T) {
	cookieValue := "existing value"

	_, resp, closeFunc, err := wsServerConnWithCookie(
		echoHandler, "clientID", cookieValue)
	defer closeFunc()
	if err != nil {
		t.Fatal(err)
	}

	cookies := resp.Cookies()
	clientID := clientID(cookies)
	if clientID != cookieValue {
		t.Errorf("clientID cookie: expected '%s', got '%s'",
			clientID,
			cookieValue)
	}
}

func TestWSClient_NewIDsAreDifferent(t *testing.T) {
	usedIDs := make(map[string]bool)

	for i := 0; i < 100; i++ {
		// Get a new client/server connection
		_, resp, closeFunc, err := wsServerConn(echoHandler)
		defer closeFunc()
		if err != nil {
			t.Fatal(err)
		}

		cookies := resp.Cookies()
		clientID := clientID(cookies)

		if usedIDs[clientID] {
			t.Errorf("Iteration i = %d, clientID '%s' already used",
				i,
				clientID)
			return
		}
		if clientID == "" {
			t.Errorf("Iteration i = %d, clientID not set", i)
			return
		}

		usedIDs[clientID] = true
		closeFunc()
	}

}
