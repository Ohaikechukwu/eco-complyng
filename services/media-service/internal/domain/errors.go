package domain

import "errors"

var (
	ErrNotFound        = errors.New("record not found")
	ErrUnauthorized    = errors.New("unauthorized")
	ErrForbidden       = errors.New("forbidden")
	ErrInvalidInput    = errors.New("invalid input")
	ErrInternalServer  = errors.New("internal server error")
	ErrUnsupportedType = errors.New("unsupported file type")
	ErrFileTooLarge    = errors.New("file exceeds maximum allowed size")
)
