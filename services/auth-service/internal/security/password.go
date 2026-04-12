package security

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/bcrypt"
)

const (
	argon2Time    uint32 = 3
	argon2Memory  uint32 = 64 * 1024
	argon2Threads uint8  = 2
	argon2KeyLen  uint32 = 32
	saltLen              = 16
)

var ErrInvalidPasswordHash = errors.New("invalid password hash")

func HashPassword(password string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}

	hash := argon2.IDKey([]byte(password), salt, argon2Time, argon2Memory, argon2Threads, argon2KeyLen)
	return fmt.Sprintf(
		"$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version,
		argon2Memory,
		argon2Time,
		argon2Threads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(hash),
	), nil
}

func VerifyAndUpgrade(storedHash, password string) (bool, string, error) {
	switch {
	case strings.HasPrefix(storedHash, "$argon2id$"):
		match, err := verifyArgon2ID(storedHash, password)
		return match, "", err
	case strings.HasPrefix(storedHash, "$2"):
		if err := bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(password)); err != nil {
			return false, "", nil
		}

		upgradedHash, err := HashPassword(password)
		if err != nil {
			return true, "", err
		}
		return true, upgradedHash, nil
	default:
		return false, "", ErrInvalidPasswordHash
	}
}

func verifyArgon2ID(encodedHash, password string) (bool, error) {
	parts := strings.Split(encodedHash, "$")
	if len(parts) != 6 {
		return false, ErrInvalidPasswordHash
	}

	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return false, ErrInvalidPasswordHash
	}

	var memory uint32
	var timeCost uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &timeCost, &threads); err != nil {
		return false, ErrInvalidPasswordHash
	}

	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false, ErrInvalidPasswordHash
	}

	hash, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false, ErrInvalidPasswordHash
	}

	keyLen, err := strconv.Atoi(strconv.Itoa(len(hash)))
	if err != nil {
		return false, ErrInvalidPasswordHash
	}

	otherHash := argon2.IDKey([]byte(password), salt, timeCost, memory, threads, uint32(keyLen))
	return subtle.ConstantTimeCompare(hash, otherHash) == 1, nil
}
