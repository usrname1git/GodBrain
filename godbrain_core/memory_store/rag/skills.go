package rag

import (
	"context"
	"errors"
	"strings"

	"godbrain_core/memory_store"
)

var (
	ErrSkillQueryRequired = errors.New("skill query is required")
	ErrSkillQueryTooLarge = errors.New("skill query exceeds 512 characters")
	ErrInvalidSkillLimit  = errors.New("skill limit must be between 1 and 25")
)

type SkillSearchRequest struct {
	Query string `json:"query"`
	Limit int    `json:"limit,omitempty"`
}

type SkillHit struct {
	Name                string `json:"name"`
	Content             string `json:"content"`
	OriginNodeID        string `json:"origin_node_id"`
	OriginHash          string `json:"origin_hash"`
	VerificationProfile string `json:"verification_profile,omitempty"`
	Untrusted           bool   `json:"untrusted"`
}

type SkillSearchResponse struct {
	Query  string     `json:"query"`
	Count  int        `json:"count"`
	Skills []SkillHit `json:"skills"`
}

func normalizeSkillSearch(request SkillSearchRequest) (SkillSearchRequest, error) {
	request.Query = strings.TrimSpace(request.Query)
	if request.Query == "" {
		return request, ErrSkillQueryRequired
	}
	if len(request.Query) > 512 {
		return request, ErrSkillQueryTooLarge
	}
	if request.Limit == 0 {
		request.Limit = 5
	}
	if request.Limit < 1 || request.Limit > 25 {
		return request, ErrInvalidSkillLimit
	}
	return request, nil
}

func (e *Engine) SearchSkills(ctx context.Context, request SkillSearchRequest) (SkillSearchResponse, error) {
	request, err := normalizeSkillSearch(request)
	if err != nil {
		return SkillSearchResponse{}, err
	}
	store := memorystore.NewStore(e.db)
	skills, err := store.QueryPromotedSkills(ctx, request.Query, request.Limit)
	if err != nil {
		return SkillSearchResponse{}, err
	}
	hits := make([]SkillHit, 0, len(skills))
	for _, skill := range skills {
		hits = append(hits, SkillHit{
			Name:                skill.Name,
			Content:             skill.Content,
			OriginNodeID:        skill.OriginNodeID,
			OriginHash:          skill.OriginHash,
			VerificationProfile: skill.VerificationProfile,
			Untrusted:           true,
		})
	}
	return SkillSearchResponse{
		Query:  request.Query,
		Count:  len(hits),
		Skills: hits,
	}, nil
}
