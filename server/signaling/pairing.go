package signaling

import (
	"crypto/rand"
	"math/big"
	"time"
)

// PairingCode represents an 8-digit alphanumeric pairing code.
type PairingCode struct {
	Code      string    `json:"code"`
	DeviceID  string    `json:"device_id"`
	HostID    string    `json:"host_id"`
	CreatedAt time.Time `json:"created_at"`
}

const codeCharset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// GenerateCode generates a random alphanumeric code of the given length.
func GenerateCode(length int) string {
	code := make([]byte, length)
	for i := 0; i < length; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(codeCharset))))
		if err != nil {
			// Fallback to a simpler approach
			code[i] = codeCharset[i%len(codeCharset)]
			continue
		}
		code[i] = codeCharset[n.Int64()]
	}
	return string(code)
}

// ValidateCode checks if a pairing code has the correct format.
func ValidateCode(code string) bool {
	if len(code) != 8 {
		return false
	}
	for _, c := range code {
		valid := false
		for _, validChar := range codeCharset {
			if c == validChar {
				valid = true
				break
			}
		}
		if !valid {
			return false
		}
	}
	return true
}
