package domain

import "errors"

var (
	ErrNotFound       = errors.New("record not found")
	ErrUnauthorized   = errors.New("unauthorized")
	ErrForbidden      = errors.New("forbidden")
	ErrInvalidInput   = errors.New("invalid input")
	ErrInternalServer = errors.New("internal server error")
	ErrShareExpired   = errors.New("share link has expired")
	ErrReportNotReady = errors.New("report is not ready yet")
)
