package handlers

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

// SMTP-disabled deployments must never turn account recovery codes into logs.
func TestAccountEmailCodesAreNotLoggedWithoutSMTP(t *testing.T) {
	originalOutput := log.Writer()
	originalHost := SMTPHost
	t.Cleanup(func() { log.SetOutput(originalOutput); SMTPHost = originalHost })
	SMTPHost = ""
	for _, send := range []func(string, string) error{sendPasswordResetEmail, sendVerificationEmail} {
		var buffer bytes.Buffer
		log.SetOutput(&buffer)
		if err := send("synthetic@example.test", "981724"); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(buffer.String(), "981724") {
			t.Fatal("account secret was logged when SMTP was disabled")
		}
	}
}
