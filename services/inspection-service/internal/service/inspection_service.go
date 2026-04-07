package service

import (
	"context"
	"time"

	"github.com/ecocomply/inspection-service/internal/domain"
	"github.com/ecocomply/inspection-service/internal/dto/request"
	"github.com/ecocomply/inspection-service/internal/dto/response"
	irepository "github.com/ecocomply/inspection-service/internal/repository/interface"
	"github.com/google/uuid"
)

type InspectionService struct {
	inspectionRepo irepository.InspectionRepository
	checklistRepo  irepository.ChecklistRepository
	actionRepo     irepository.ActionRepository
}

func NewInspectionService(
	inspectionRepo irepository.InspectionRepository,
	checklistRepo irepository.ChecklistRepository,
	actionRepo irepository.ActionRepository,
) *InspectionService {
	return &InspectionService{
		inspectionRepo: inspectionRepo,
		checklistRepo:  checklistRepo,
		actionRepo:     actionRepo,
	}
}

// --- Dashboard ---

func (s *InspectionService) Dashboard(ctx context.Context, userID uuid.UUID, role, inspectorName, inspectorRole string) (*response.DashboardResponse, error) {
	counts, err := s.inspectionRepo.Dashboard(ctx, userID, role)
	if err != nil {
		return nil, err
	}

	// Recent 5 inspections
	recent, _, err := s.inspectionRepo.List(ctx, irepository.ListFilters{
		UserID: userID,
		Role:   role,
		Limit:  5,
		Offset: 0,
	})
	if err != nil {
		return nil, err
	}

	var recentRes []response.InspectionResponse
	for _, i := range recent {
		recentRes = append(recentRes, toInspectionResponse(&i, false))
	}

	return &response.DashboardResponse{
		Total:          counts.Total,
		Draft:          counts.Draft,
		InProgress:     counts.InProgress,
		Submitted:      counts.Submitted,
		UnderReview:    counts.UnderReview,
		PendingActions: counts.PendingActions,
		Completed:      counts.Completed,
		Finalized:      counts.Finalized,
		Recent:         recentRes,
	}, nil
}

func (s *InspectionService) Analytics(ctx context.Context, userID uuid.UUID, role string) (*response.AnalyticsResponse, error) {
	counts, err := s.inspectionRepo.Dashboard(ctx, userID, role)
	if err != nil {
		return nil, err
	}

	inspections, _, err := s.inspectionRepo.List(ctx, irepository.ListFilters{
		UserID: userID,
		Role:   role,
		Limit:  1000,
		Offset: 0,
	})
	if err != nil {
		return nil, err
	}

	res := &response.AnalyticsResponse{
		StatusCounts: map[string]int64{
			"draft":           counts.Draft,
			"in_progress":     counts.InProgress,
			"submitted":       counts.Submitted,
			"under_review":    counts.UnderReview,
			"pending_actions": counts.PendingActions,
			"completed":       counts.Completed,
			"finalized":       counts.Finalized,
		},
	}

	for _, inspection := range inspections {
		if inspection.Latitude != nil || inspection.Longitude != nil || inspection.LocationName != "" {
			res.InspectionLocations = append(res.InspectionLocations, response.InspectionMapItem{
				ID:           inspection.ID.String(),
				ProjectName:  inspection.ProjectName,
				LocationName: inspection.LocationName,
				Latitude:     inspection.Latitude,
				Longitude:    inspection.Longitude,
				Status:       string(inspection.Status),
				Date:         inspection.Date,
			})
		}

		detailed, detailErr := s.inspectionRepo.FindByIDWithDetails(ctx, inspection.ID)
		if detailErr != nil {
			continue
		}

		for _, item := range detailed.ChecklistItems {
			switch {
			case item.Response == nil:
				res.ChecklistSummary.Unanswered++
			case *item.Response:
				res.ChecklistSummary.Conformance++
			default:
				res.ChecklistSummary.NonConformance++
			}
		}

		for _, action := range detailed.AgreedActions {
			isOverdue := action.Status == domain.ActionOverdue || (action.Status != domain.ActionResolved && action.DueDate.Before(time.Now()))
			switch action.Status {
			case domain.ActionPending:
				res.ActionSummary.Pending++
				res.RecentPendingActionIDs = append(res.RecentPendingActionIDs, action.ID.String())
			case domain.ActionInProgress:
				res.ActionSummary.InProgress++
			case domain.ActionResolved:
				res.ActionSummary.Resolved++
			}
			if isOverdue {
				res.ActionSummary.Overdue++
			}
		}
	}

	return res, nil
}

func (s *InspectionService) AnalyticsCompare(ctx context.Context, userID uuid.UUID, role string, from, to time.Time) (*response.AnalyticsCompareResponse, error) {
	current, err := s.analyticsSnapshot(ctx, userID, role, from, to)
	if err != nil {
		return nil, err
	}
	span := to.Sub(from)
	prevTo := from
	prevFrom := from.Add(-span)
	previous, err := s.analyticsSnapshot(ctx, userID, role, prevFrom, prevTo)
	if err != nil {
		return nil, err
	}
	return &response.AnalyticsCompareResponse{
		CurrentPeriod:  current,
		PreviousPeriod: previous,
	}, nil
}

func (s *InspectionService) AnalyticsGeoJSON(ctx context.Context, userID uuid.UUID, role string) (*response.GeoJSONResponse, error) {
	inspections, _, err := s.inspectionRepo.List(ctx, irepository.ListFilters{
		UserID: userID,
		Role:   role,
		Limit:  1000,
		Offset: 0,
	})
	if err != nil {
		return nil, err
	}
	res := &response.GeoJSONResponse{Type: "FeatureCollection"}
	for _, inspection := range inspections {
		if inspection.Latitude == nil || inspection.Longitude == nil {
			continue
		}
		res.Features = append(res.Features, response.GeoJSONFeature{
			Type: "Feature",
			Geometry: response.GeoJSONGeometry{
				Type:        "Point",
				Coordinates: []float64{*inspection.Longitude, *inspection.Latitude},
			},
			Properties: map[string]interface{}{
				"id":            inspection.ID.String(),
				"project_name":  inspection.ProjectName,
				"location_name": inspection.LocationName,
				"status":        string(inspection.Status),
				"date":          inspection.Date,
			},
		})
	}
	return res, nil
}

func (s *InspectionService) analyticsSnapshot(ctx context.Context, userID uuid.UUID, role string, from, to time.Time) (response.AnalyticsSnapshot, error) {
	inspections, _, err := s.inspectionRepo.List(ctx, irepository.ListFilters{
		UserID: userID,
		Role:   role,
		Limit:  1000,
		Offset: 0,
	})
	if err != nil {
		return response.AnalyticsSnapshot{}, err
	}
	snap := response.AnalyticsSnapshot{
		From:         from,
		To:           to,
		StatusCounts: map[string]int64{},
	}
	for _, inspection := range inspections {
		if inspection.Date.Before(from) || inspection.Date.After(to) {
			continue
		}
		snap.Total++
		snap.StatusCounts[string(inspection.Status)]++
	}
	return snap, nil
}

// --- Inspections ---

func (s *InspectionService) Create(ctx context.Context, userID uuid.UUID, inspectorName, inspectorRole string, req request.CreateInspectionRequest) (*response.InspectionResponse, error) {
	inspection := &domain.Inspection{
		ProjectName:    req.ProjectName,
		LocationName:   req.LocationName,
		Latitude:       req.Latitude,
		Longitude:      req.Longitude,
		Date:           time.Now(),
		InspectorName:  inspectorName,
		InspectorRole:  inspectorRole,
		AssignedUserID: userID,
		Notes:          req.Notes,
		Status:         domain.StatusDraft,
	}

	// Attach checklist template if provided
	if req.ChecklistID != "" {
		templateID, err := uuid.Parse(req.ChecklistID)
		if err != nil {
			return nil, domain.ErrInvalidInput
		}
		inspection.ChecklistID = &templateID
	}

	if err := s.inspectionRepo.Create(ctx, inspection); err != nil {
		return nil, err
	}

	// If a template was provided, copy its items onto this inspection
	if inspection.ChecklistID != nil {
		template, err := s.checklistRepo.FindTemplateByID(ctx, *inspection.ChecklistID)
		if err == nil && len(template.Items) > 0 {
			var items []domain.ChecklistItem
			for _, ti := range template.Items {
				tid := ti.ID
				items = append(items, domain.ChecklistItem{
					InspectionID:   inspection.ID,
					TemplateItemID: &tid,
					Description:    ti.Description,
					SortOrder:      ti.SortOrder,
				})
			}
			_ = s.checklistRepo.CreateItems(ctx, items)
		}
	}

	res := toInspectionResponse(inspection, false)
	return &res, nil
}

func (s *InspectionService) GetByID(ctx context.Context, id uuid.UUID) (*response.InspectionResponse, error) {
	inspection, err := s.inspectionRepo.FindByIDWithDetails(ctx, id)
	if err != nil {
		return nil, err
	}
	res := toInspectionResponse(inspection, true)
	return &res, nil
}

func (s *InspectionService) SyncPull(ctx context.Context, since time.Time, userID uuid.UUID, role string) (*response.SyncPullResponse, error) {
	changed, err := s.inspectionRepo.FindChangedSince(ctx, since, userID, role)
	if err != nil {
		return nil, err
	}
	deleted, err := s.inspectionRepo.FindDeletedSince(ctx, since, userID, role)
	if err != nil {
		return nil, err
	}
	res := &response.SyncPullResponse{ServerTime: time.Now()}
	for _, item := range changed {
		detail, detailErr := s.inspectionRepo.FindByIDWithDetails(ctx, item.ID)
		if detailErr != nil {
			continue
		}
		resp := toInspectionResponse(detail, true)
		res.Inspections = append(res.Inspections, resp)
	}
	for _, id := range deleted {
		res.DeletedIDs = append(res.DeletedIDs, id.String())
	}
	return res, nil
}

func (s *InspectionService) Update(ctx context.Context, id uuid.UUID, req request.UpdateInspectionRequest) (*response.InspectionResponse, error) {
	inspection, err := s.inspectionRepo.FindByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if inspection.Status != domain.StatusDraft && inspection.Status != domain.StatusInProgress {
		return nil, domain.ErrForbidden
	}

	if req.ProjectName != "" {
		inspection.ProjectName = req.ProjectName
	}
	if req.LocationName != "" {
		inspection.LocationName = req.LocationName
	}
	if req.Latitude != nil {
		inspection.Latitude = req.Latitude
	}
	if req.Longitude != nil {
		inspection.Longitude = req.Longitude
	}
	if req.Notes != "" {
		inspection.Notes = req.Notes
	}

	if err := s.inspectionRepo.Update(ctx, inspection); err != nil {
		return nil, err
	}
	res := toInspectionResponse(inspection, false)
	return &res, nil
}

func (s *InspectionService) OfflineMerge(ctx context.Context, id uuid.UUID, req request.OfflineMergeRequest) (*response.InspectionResponse, *response.MergeConflictResponse, error) {
	inspection, err := s.inspectionRepo.FindByID(ctx, id)
	if err != nil {
		return nil, nil, err
	}
	clientUpdatedAt, err := time.Parse(time.RFC3339, req.ClientUpdatedAt)
	if err != nil {
		return nil, nil, domain.ErrInvalidInput
	}
	if inspection.UpdatedAt.After(clientUpdatedAt) {
		serverDetail, detailErr := s.inspectionRepo.FindByIDWithDetails(ctx, id)
		if detailErr != nil {
			return nil, nil, detailErr
		}
		return nil, &response.MergeConflictResponse{
			Message:          "server version is newer than client version",
			ServerInspection: toInspectionResponse(serverDetail, true),
		}, nil
	}
	updateReq := request.UpdateInspectionRequest{
		ProjectName:  req.ProjectName,
		LocationName: req.LocationName,
		Latitude:     req.Latitude,
		Longitude:    req.Longitude,
		Notes:        req.Notes,
	}
	res, err := s.Update(ctx, id, updateReq)
	if err != nil {
		return nil, nil, err
	}
	if req.Status != "" {
		if _, err := s.TransitionStatus(ctx, id, request.TransitionStatusRequest{Status: req.Status}); err != nil {
			return nil, nil, err
		}
		res, err = s.GetByID(ctx, id)
		if err != nil {
			return nil, nil, err
		}
	}
	return res, nil, nil
}

func (s *InspectionService) TransitionStatus(ctx context.Context, id uuid.UUID, req request.TransitionStatusRequest) (*response.InspectionResponse, error) {
	inspection, err := s.inspectionRepo.FindByID(ctx, id)
	if err != nil {
		return nil, err
	}

	next := domain.InspectionStatus(req.Status)
	if !inspection.Status.CanTransitionTo(next) {
		return nil, domain.ErrInvalidTransition
	}

	inspection.Status = next
	if err := s.inspectionRepo.Update(ctx, inspection); err != nil {
		return nil, err
	}
	res := toInspectionResponse(inspection, false)
	return &res, nil
}

func (s *InspectionService) Delete(ctx context.Context, id uuid.UUID) error {
	inspection, err := s.inspectionRepo.FindByID(ctx, id)
	if err != nil {
		return err
	}
	if inspection.Status != domain.StatusDraft {
		return domain.ErrForbidden
	}
	return s.inspectionRepo.SoftDelete(ctx, id)
}

func (s *InspectionService) List(ctx context.Context, userID uuid.UUID, role string, req request.ListInspectionsRequest) (*response.InspectionListResponse, error) {
	if req.Limit <= 0 || req.Limit > 100 {
		req.Limit = 20
	}
	if req.Page <= 0 {
		req.Page = 1
	}
	offset := (req.Page - 1) * req.Limit

	inspections, total, err := s.inspectionRepo.List(ctx, irepository.ListFilters{
		Status: req.Status,
		Search: req.Search,
		UserID: userID,
		Role:   role,
		Limit:  req.Limit,
		Offset: offset,
	})
	if err != nil {
		return nil, err
	}

	var res []response.InspectionResponse
	for _, i := range inspections {
		res = append(res, toInspectionResponse(&i, false))
	}

	totalPages := int(total) / req.Limit
	if int(total)%req.Limit != 0 {
		totalPages++
	}

	return &response.InspectionListResponse{
		Inspections: res,
		Total:       total,
		Page:        req.Page,
		Limit:       req.Limit,
		TotalPages:  totalPages,
	}, nil
}

// --- Checklist ---

func (s *InspectionService) CreateTemplate(ctx context.Context, userID uuid.UUID, req request.CreateTemplateRequest) (*response.ChecklistTemplateResponse, error) {
	template := &domain.ChecklistTemplate{
		Name:        req.Name,
		Description: req.Description,
		IsSystem:    false,
		CreatedBy:   userID,
	}
	for i, item := range req.Items {
		template.Items = append(template.Items, domain.ChecklistTemplateItem{
			Description: item.Description,
			SortOrder:   i,
		})
	}
	if err := s.checklistRepo.CreateTemplate(ctx, template); err != nil {
		return nil, err
	}
	res := toTemplateResponse(template)
	return &res, nil
}

func (s *InspectionService) ListTemplates(ctx context.Context) ([]response.ChecklistTemplateResponse, error) {
	templates, err := s.checklistRepo.ListTemplates(ctx)
	if err != nil {
		return nil, err
	}
	var res []response.ChecklistTemplateResponse
	for _, t := range templates {
		res = append(res, toTemplateResponse(&t))
	}
	return res, nil
}

func (s *InspectionService) UpdateChecklistItem(ctx context.Context, itemID uuid.UUID, req request.UpdateChecklistItemRequest) (*response.ChecklistItemResponse, error) {
	item, err := s.checklistRepo.FindItemByID(ctx, itemID)
	if err != nil {
		return nil, err
	}
	item.Response = req.Response
	item.Comment = req.Comment
	if err := s.checklistRepo.UpdateItem(ctx, item); err != nil {
		return nil, err
	}
	res := toChecklistItemResponse(item)
	return &res, nil
}

func (s *InspectionService) AddChecklistItem(ctx context.Context, inspectionID uuid.UUID, req request.AddChecklistItemRequest) (*response.ChecklistItemResponse, error) {
	item := &domain.ChecklistItem{
		InspectionID: inspectionID,
		Description:  req.Description,
		SortOrder:    req.SortOrder,
	}
	if err := s.checklistRepo.AddItem(ctx, item); err != nil {
		return nil, err
	}
	res := toChecklistItemResponse(item)
	return &res, nil
}

// --- Actions ---

func (s *InspectionService) CreateAction(ctx context.Context, inspectionID, createdBy uuid.UUID, req request.CreateActionRequest) (*response.ActionResponse, error) {
	assigneeID, err := uuid.Parse(req.AssigneeID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}
	dueDate, err := time.Parse(time.RFC3339, req.DueDate)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}
	action := &domain.AgreedAction{
		InspectionID: inspectionID,
		Description:  req.Description,
		AssigneeID:   assigneeID,
		DueDate:      dueDate,
		Status:       domain.ActionPending,
		CreatedBy:    createdBy,
	}
	if err := s.actionRepo.Create(ctx, action); err != nil {
		return nil, err
	}
	res := toActionResponse(action)
	return &res, nil
}

func (s *InspectionService) UpdateAction(ctx context.Context, actionID uuid.UUID, req request.UpdateActionRequest) (*response.ActionResponse, error) {
	action, err := s.actionRepo.FindByID(ctx, actionID)
	if err != nil {
		return nil, err
	}
	if req.Status != "" {
		action.Status = domain.ActionStatus(req.Status)
		if action.Status == domain.ActionResolved {
			now := time.Now()
			action.ResolvedAt = &now
		}
	}
	if req.EvidenceURL != "" {
		action.EvidenceURL = req.EvidenceURL
	}
	if err := s.actionRepo.Update(ctx, action); err != nil {
		return nil, err
	}
	res := toActionResponse(action)
	return &res, nil
}

func (s *InspectionService) AddComment(ctx context.Context, inspectionID, authorID uuid.UUID, req request.AddCommentRequest) (*response.CommentResponse, error) {
	comment := &domain.InspectionComment{
		InspectionID: inspectionID,
		AuthorID:     authorID,
		Body:         req.Body,
	}
	if err := s.actionRepo.AddComment(ctx, comment); err != nil {
		return nil, err
	}
	res := toCommentResponse(comment)
	return &res, nil
}

func (s *InspectionService) CreateReview(ctx context.Context, inspectionID, reviewerID uuid.UUID, role string, req request.CreateReviewRequest) (*response.ReviewResponse, error) {
	inspection, err := s.inspectionRepo.FindByID(ctx, inspectionID)
	if err != nil {
		return nil, err
	}
	assignedToID, err := uuid.Parse(req.AssignedToID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}
	dueDate, err := time.Parse(time.RFC3339, req.DueDate)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}
	stage := domain.ReviewStageSupervisor
	if role == "manager" {
		stage = domain.ReviewStageManager
	}
	review := &domain.InspectionReview{
		InspectionID: inspectionID,
		Stage:        stage,
		ReviewerID:   reviewerID,
		AssignedToID: assignedToID,
		Comment:      req.Comment,
		DueDate:      dueDate,
		Status:       domain.ReviewOpen,
	}
	if err := s.actionRepo.CreateReview(ctx, review); err != nil {
		return nil, err
	}
	inspection.Status = domain.StatusPendingActions
	if err := s.inspectionRepo.Update(ctx, inspection); err != nil {
		return nil, err
	}
	res := toReviewResponse(review)
	return &res, nil
}

func (s *InspectionService) UpdateReview(ctx context.Context, reviewID, userID uuid.UUID, role string, req request.UpdateReviewRequest) (*response.ReviewResponse, error) {
	review, err := s.actionRepo.FindReviewByID(ctx, reviewID)
	if err != nil {
		return nil, err
	}
	if req.Status == string(domain.ReviewAddressed) && review.AssignedToID != userID {
		return nil, domain.ErrForbidden
	}
	if (req.Status == string(domain.ReviewApproved) || req.Status == string(domain.ReviewRejected)) && review.ReviewerID != userID && role != "org_admin" {
		return nil, domain.ErrForbidden
	}
	review.Status = domain.ReviewStatus(req.Status)
	review.ResponseComment = req.ResponseComment
	now := time.Now()
	review.ResolvedAt = &now
	if err := s.actionRepo.UpdateReview(ctx, review); err != nil {
		return nil, err
	}

	inspection, err := s.inspectionRepo.FindByID(ctx, review.InspectionID)
	if err != nil {
		return nil, err
	}
	switch review.Status {
	case domain.ReviewAddressed:
		inspection.Status = domain.StatusUnderReview
	case domain.ReviewApproved:
		if review.Stage == domain.ReviewStageManager {
			inspection.Status = domain.StatusFinalized
		} else {
			inspection.Status = domain.StatusCompleted
		}
	case domain.ReviewRejected:
		inspection.Status = domain.StatusPendingActions
	}
	if err := s.inspectionRepo.Update(ctx, inspection); err != nil {
		return nil, err
	}
	res := toReviewResponse(review)
	return &res, nil
}

// --- mappers ---

func toInspectionResponse(i *domain.Inspection, withDetails bool) response.InspectionResponse {
	var checklistID *string
	if i.ChecklistID != nil {
		s := i.ChecklistID.String()
		checklistID = &s
	}
	res := response.InspectionResponse{
		ID:             i.ID.String(),
		ProjectName:    i.ProjectName,
		LocationName:   i.LocationName,
		Latitude:       i.Latitude,
		Longitude:      i.Longitude,
		Date:           i.Date,
		InspectorName:  i.InspectorName,
		InspectorRole:  i.InspectorRole,
		AssignedUserID: i.AssignedUserID.String(),
		ChecklistID:    checklistID,
		Status:         string(i.Status),
		Notes:          i.Notes,
		CreatedAt:      i.CreatedAt,
		UpdatedAt:      i.UpdatedAt,
	}
	if withDetails {
		for _, ci := range i.ChecklistItems {
			res.ChecklistItems = append(res.ChecklistItems, toChecklistItemResponse(&ci))
		}
		for _, a := range i.AgreedActions {
			res.AgreedActions = append(res.AgreedActions, toActionResponse(&a))
		}
		for _, c := range i.Comments {
			res.Comments = append(res.Comments, toCommentResponse(&c))
		}
		for _, r := range i.Reviews {
			res.Reviews = append(res.Reviews, toReviewResponse(&r))
		}
	}
	return res
}

func toChecklistItemResponse(i *domain.ChecklistItem) response.ChecklistItemResponse {
	return response.ChecklistItemResponse{
		ID:          i.ID.String(),
		Description: i.Description,
		Response:    i.Response,
		Comment:     i.Comment,
		SortOrder:   i.SortOrder,
	}
}

func toActionResponse(a *domain.AgreedAction) response.ActionResponse {
	return response.ActionResponse{
		ID:          a.ID.String(),
		Description: a.Description,
		AssigneeID:  a.AssigneeID.String(),
		DueDate:     a.DueDate,
		Status:      string(a.Status),
		EvidenceURL: a.EvidenceURL,
		ResolvedAt:  a.ResolvedAt,
		CreatedAt:   a.CreatedAt,
	}
}

func toCommentResponse(c *domain.InspectionComment) response.CommentResponse {
	return response.CommentResponse{
		ID:        c.ID.String(),
		AuthorID:  c.AuthorID.String(),
		Body:      c.Body,
		CreatedAt: c.CreatedAt,
	}
}

func toReviewResponse(r *domain.InspectionReview) response.ReviewResponse {
	return response.ReviewResponse{
		ID:              r.ID.String(),
		Stage:           string(r.Stage),
		ReviewerID:      r.ReviewerID.String(),
		AssignedToID:    r.AssignedToID.String(),
		Comment:         r.Comment,
		DueDate:         r.DueDate,
		Status:          string(r.Status),
		ResponseComment: r.ResponseComment,
		ResolvedAt:      r.ResolvedAt,
		CreatedAt:       r.CreatedAt,
	}
}

func toTemplateResponse(t *domain.ChecklistTemplate) response.ChecklistTemplateResponse {
	res := response.ChecklistTemplateResponse{
		ID:          t.ID.String(),
		Name:        t.Name,
		Description: t.Description,
		IsSystem:    t.IsSystem,
		CreatedBy:   t.CreatedBy.String(),
		CreatedAt:   t.CreatedAt,
	}
	for _, item := range t.Items {
		res.Items = append(res.Items, response.TemplateItemResponse{
			ID:          item.ID.String(),
			Description: item.Description,
			SortOrder:   item.SortOrder,
		})
	}
	return res
}
