package jwt

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

type Claims struct {
	UserID    string `json:"user_id"`
	Name      string `json:"name"`
	OrgID     string `json:"org_id"`
	OrgSchema string `json:"org_schema"`
	Role      string `json:"role"`
	jwt.RegisteredClaims
}

type Manager struct {
	secret      []byte
	expiryHours int
}

func NewManager(secret string, expiryHours int) *Manager {
	return &Manager{secret: []byte(secret), expiryHours: expiryHours}
}

func (m *Manager) Sign(userID, name, orgID, orgSchema, role string) (string, error) {
	claims := Claims{
		UserID:    userID,
		Name:      name,
		OrgID:     orgID,
		OrgSchema: orgSchema,
		Role:      role,
		RegisteredClaims: jwt.RegisteredClaims{
			ID:        uuid.NewString(),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Duration(m.expiryHours) * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(m.secret)
}

func (m *Manager) Verify(tokenStr string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, errors.New("unexpected signing method")
		}
		return m.secret, nil
	})
	if err != nil || !token.Valid {
		return nil, errors.New("invalid or expired token")
	}
	claims, ok := token.Claims.(*Claims)
	if !ok {
		return nil, errors.New("invalid claims")
	}
	return claims, nil
}
