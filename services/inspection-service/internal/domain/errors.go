package domain

import "errors"

var (
	ErrNotFound            = errors.New("record not found")
	ErrUnauthorized        = errors.New("unauthorized")
	ErrForbidden           = errors.New("forbidden")
	ErrAlreadyExists       = errors.New("record already exists")
	ErrInvalidInput        = errors.New("invalid input")
	ErrInternalServer      = errors.New("internal server error")
	ErrInvalidTransition   = errors.New("invalid status transition")
	ErrChecklistIncomplete = errors.New("checklist has unanswered items")
)
