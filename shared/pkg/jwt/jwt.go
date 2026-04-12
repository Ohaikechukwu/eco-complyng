package jwt

import (
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const AccessTokenType = "access"

type Claims struct {
	UserID    string `json:"user_id"`
	Name      string `json:"name"`
	OrgID     string `json:"org_id"`
	OrgSchema string `json:"org_schema"`
	Role      string `json:"role"`
	TokenType string `json:"token_type"`
	jwt.RegisteredClaims
}

type Manager struct {
	secret    []byte
	expiry    time.Duration
	issuer    string
	audience  []string
	tokenType string
}

func NewManager(secret string, expiryHours int) *Manager {
	expiry := time.Duration(expiryHours) * time.Hour
	if expiry <= 0 {
		expiry = 15 * time.Minute
	}

	return &Manager{
		secret:    []byte(secret),
		expiry:    expiry,
		tokenType: AccessTokenType,
	}
}

func (m *Manager) WithIssuer(issuer string) *Manager {
	m.issuer = strings.TrimSpace(issuer)
	return m
}

func (m *Manager) WithAudience(audience ...string) *Manager {
	m.audience = m.audience[:0]
	for _, entry := range audience {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		m.audience = append(m.audience, entry)
	}
	return m
}

func (m *Manager) WithAccessTTL(ttl time.Duration) *Manager {
	if ttl > 0 {
		m.expiry = ttl
	}
	return m
}

func (m *Manager) AccessTTL() time.Duration {
	return m.expiry
}

func (m *Manager) Sign(userID, name, orgID, orgSchema, role string) (string, error) {
	now := time.Now().UTC()
	claims := Claims{
		UserID:    userID,
		Name:      name,
		OrgID:     orgID,
		OrgSchema: orgSchema,
		Role:      role,
		TokenType: m.tokenType,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			Issuer:    m.issuer,
			Audience:  m.audience,
			ID:        uuid.NewString(),
			ExpiresAt: jwt.NewNumericDate(now.Add(m.expiry)),
			IssuedAt:  jwt.NewNumericDate(now),
			NotBefore: jwt.NewNumericDate(now),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(m.secret)
}

func (m *Manager) Verify(tokenStr string) (*Claims, error) {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuedAt(),
	)

	token, err := parser.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (interface{}, error) {
		return m.secret, nil
	})
	if err != nil || !token.Valid {
		return nil, errors.New("invalid or expired token")
	}
	claims, ok := token.Claims.(*Claims)
	if !ok {
		return nil, errors.New("invalid claims")
	}
	if claims.UserID == "" {
		claims.UserID = claims.Subject
	}
	if claims.UserID == "" || claims.Subject == "" {
		return nil, errors.New("invalid subject")
	}
	if m.issuer != "" && claims.Issuer != m.issuer {
		return nil, errors.New("invalid issuer")
	}
	if len(m.audience) > 0 && !hasAudienceIntersection(claims.Audience, m.audience) {
		return nil, errors.New("invalid audience")
	}
	if m.tokenType != "" && claims.TokenType != m.tokenType {
		return nil, errors.New("invalid token type")
	}
	return claims, nil
}

func hasAudienceIntersection(actual jwt.ClaimStrings, expected []string) bool {
	for _, audience := range actual {
		if slices.Contains(expected, audience) {
			return true
		}
	}
	return false
}
