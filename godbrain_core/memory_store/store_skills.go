package memorystore

import (
	"context"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/sha3"
)

var allowedSkillProfiles = map[string]struct{}{
	"local-edit-apply-v1": {},
	"galaxy-html-v1":      {},
	"frontend-spa-v1":     {},
	"frontend-nextjs-v1":  {},
	"desk-v1":             {},
}

var applyOnlySkillProfiles = map[string]struct{}{
	"local-edit-apply-v1": {},
}

var suiteRequiredSkillProfiles = map[string]struct{}{
	"galaxy-html-v1":     {},
	"frontend-spa-v1":    {},
	"frontend-nextjs-v1": {},
}

func latestSkillRunSort() bson.D {
	return bson.D{{Key: "created_at", Value: -1}, {Key: "_id", Value: -1}}
}

func normalizeSkillExtracted(skill SkillExtracted) SkillExtracted {
	skill.Name = strings.TrimSpace(skill.Name)
	skill.Content = strings.TrimSpace(skill.Content)
	skill.TaskKind = strings.ToLower(strings.Join(strings.Fields(skill.TaskKind), " "))
	skill.Framework = strings.ToLower(strings.TrimSpace(skill.Framework))
	skill.VerificationProfile = strings.TrimSpace(skill.VerificationProfile)
	if skill.VerificationProfile != "" {
		if _, ok := allowedSkillProfiles[skill.VerificationProfile]; !ok {
			skill.VerificationProfile = ""
		}
	}
	inputs := make([]string, 0, len(skill.RequiredInputs))
	for _, input := range skill.RequiredInputs {
		input = strings.TrimSpace(input)
		if input != "" {
			inputs = append(inputs, input)
		}
	}
	skill.RequiredInputs = inputs
	steps := make([]string, 0, len(skill.Procedure))
	for _, step := range skill.Procedure {
		step = strings.TrimSpace(step)
		if step != "" {
			steps = append(steps, step)
		}
	}
	skill.Procedure = steps
	return skill
}

func skillProcedureText(skill SkillExtracted) string {
	if skill.Content != "" {
		return skill.Content
	}
	return strings.Join(skill.Procedure, "\n")
}

func skillStableID(name, content string) string {
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte("skill\x00" + name + "\x00" + content))
	return hex.EncodeToString(hash.Sum(nil))
}

func validateSkillExtracted(skill SkillExtracted) error {
	if !safeExtractorIDPattern.MatchString(skill.Name) {
		return ErrInvalidSkillExtracted
	}
	content := skillProcedureText(skill)
	if content == "" || len(content) > 8192 {
		return ErrInvalidSkillExtracted
	}
	if len(skill.Procedure) > 32 {
		return ErrInvalidSkillExtracted
	}
	for _, step := range skill.Procedure {
		if len(step) > 512 {
			return ErrInvalidSkillExtracted
		}
	}
	if len(skill.RequiredInputs) > 16 {
		return ErrInvalidSkillExtracted
	}
	if skill.TaskKind != "" && (len(skill.TaskKind) > 64 || !safeExtractorIDPattern.MatchString(strings.ReplaceAll(skill.TaskKind, " ", "-"))) {
		return ErrInvalidSkillExtracted
	}
	if skill.Framework != "" && (len(skill.Framework) > 64 || !safeExtractorIDPattern.MatchString(skill.Framework)) {
		return ErrInvalidSkillExtracted
	}
	if skill.Confidence < 0 || skill.Confidence > 1 {
		return ErrInvalidSkillExtracted
	}
	return nil
}

func ValidateRecordSkillRun(request RecordSkillRunRequest) error {
	if request.Command != RecordSkillRunCommand {
		return ErrInvalidSkillRun
	}
	if !safeExtractorIDPattern.MatchString(request.SkillName) {
		return ErrInvalidSkillRun
	}
	if strings.TrimSpace(request.OriginNodeID) == "" || len(request.OriginNodeID) > 64 {
		return ErrInvalidSkillRun
	}
	if strings.TrimSpace(request.FixtureID) == "" || len(request.FixtureID) > 128 {
		return ErrInvalidSkillRun
	}
	if len(strings.TrimSpace(request.SuiteID)) > 128 {
		return ErrInvalidSkillRun
	}
	if len(strings.TrimSpace(request.VerificationVersion)) > 32 {
		return ErrInvalidSkillRun
	}
	if _, ok := allowedSkillProfiles[request.VerificationProfile]; !ok {
		return ErrInvalidSkillProfile
	}
	if request.Result != SkillRunPassed && request.Result != SkillRunFailed {
		return ErrInvalidSkillRun
	}
	if len(request.Checks) > 16 {
		return ErrInvalidSkillRun
	}
	for key, value := range request.Checks {
		if len(key) > 64 || len(value) > 64 {
			return ErrInvalidSkillRun
		}
	}
	if len(request.EnvironmentHash) > 128 || len(request.ArtifactHash) > 128 {
		return ErrInvalidSkillRun
	}
	if len(request.LogExcerpt) > 4096 {
		return ErrInvalidSkillRun
	}
	if len(strings.TrimSpace(request.Reasoning)) < MinJudgmentReason ||
		len(request.Reasoning) > MaxJudgmentReason {
		return ErrJudgmentReasoningRequired
	}
	return nil
}

func ValidatePromoteSkillRequest(request PromoteSkillRequest) error {
	if request.Command != PromoteSkillCommand {
		return ErrInvalidSkillRun
	}
	if !safeExtractorIDPattern.MatchString(request.Name) {
		return ErrInvalidSkillExtracted
	}
	if strings.TrimSpace(request.OriginNodeID) == "" {
		return ErrKnowledgeNodeNotFound
	}
	if strings.TrimSpace(request.OriginVersion) == "" || strings.TrimSpace(request.OriginHash) == "" {
		return ErrSkillOriginHashMismatch
	}
	if request.SchemaVersion == "" || len(request.SchemaVersion) > 64 {
		return ErrInvalidSkillExtracted
	}
	if len(strings.TrimSpace(request.Reasoning)) < MinJudgmentReason ||
		len(request.Reasoning) > MaxJudgmentReason {
		return ErrJudgmentReasoningRequired
	}
	if request.VerificationProfile != "" {
		if _, ok := allowedSkillProfiles[request.VerificationProfile]; !ok {
			return ErrInvalidSkillProfile
		}
	}
	return nil
}

func ValidateQuerySkillsRequest(request QuerySkillsRequest) error {
	if request.Command != QuerySkillsCommand {
		return ErrInvalidSkillRun
	}
	if len(request.Query) > 512 {
		return ErrInvalidSkillRun
	}
	return nil
}

func (s *Store) RecordSkillVerificationRun(ctx context.Context, request RecordSkillRunRequest) (*SkillVerificationRun, error) {
	if err := ValidateRecordSkillRun(request); err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	run := SkillVerificationRun{
		RunID:               uuid.NewString(),
		SkillName:           request.SkillName,
		OriginNodeID:        strings.TrimSpace(request.OriginNodeID),
		FixtureID:           strings.TrimSpace(request.FixtureID),
		SuiteID:             strings.TrimSpace(request.SuiteID),
		VerificationProfile: request.VerificationProfile,
		VerificationVersion: strings.TrimSpace(request.VerificationVersion),
		EnvironmentHash:     strings.TrimSpace(request.EnvironmentHash),
		Result:              request.Result,
		Checks:              request.Checks,
		ArtifactHash:        strings.TrimSpace(request.ArtifactHash),
		LogExcerpt:          request.LogExcerpt,
		Reasoning:           strings.TrimSpace(request.Reasoning),
		CreatedAt:           now,
	}
	if _, err := s.db.Collection("skill_verification_runs").InsertOne(ctx, run); err != nil {
		return nil, err
	}
	return &run, nil
}

func (s *Store) requirePassingSkillRun(ctx context.Context, originNodeID, skillName string) (*SkillVerificationRun, error) {
	opts := options.FindOne().SetSort(latestSkillRunSort())
	var latest SkillVerificationRun
	err := s.db.Collection("skill_verification_runs").FindOne(ctx, bson.M{
		"origin_node_id": originNodeID,
		"skill_name":     skillName,
	}, opts).Decode(&latest)
	if err != nil {
		if errors.Is(err, mongo.ErrNoDocuments) {
			return nil, ErrSkillVerificationRequired
		}
		return nil, err
	}
	if latest.Result != SkillRunPassed {
		return nil, ErrSkillVerificationStale
	}
	if _, applyOnly := applyOnlySkillProfiles[latest.VerificationProfile]; applyOnly {
		return nil, ErrSkillApplyOnlyProfile
	}
	if _, needSuite := suiteRequiredSkillProfiles[latest.VerificationProfile]; needSuite {
		if err := s.requireDistinctPassingFixtures(
			ctx, originNodeID, skillName, latest.VerificationProfile, 2); err != nil {
			return nil, err
		}
	}
	return &latest, nil
}

func suiteRequiredProfile(profile string) bool {
	_, ok := suiteRequiredSkillProfiles[profile]
	return ok
}

func (s *Store) requireDistinctPassingFixtures(
	ctx context.Context,
	originNodeID, skillName, profile string,
	min int,
) error {
	opts := options.Find().SetSort(latestSkillRunSort()).SetLimit(50)
	cursor, err := s.db.Collection("skill_verification_runs").Find(ctx, bson.M{
		"origin_node_id":       originNodeID,
		"skill_name":           skillName,
		"verification_profile": profile,
	}, opts)
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	var runs []SkillVerificationRun
	if err = cursor.All(ctx, &runs); err != nil {
		return err
	}
	if currentPassingFixtureCount(runs) < min {
		return ErrSkillSuiteRequired
	}
	return nil
}

// runs must be latest-first. Only the newest run per fixture counts.
func currentPassingFixtureCount(runs []SkillVerificationRun) int {
	seen := map[string]struct{}{}
	n := 0
	for _, run := range runs {
		id := strings.TrimSpace(run.FixtureID)
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		if run.Result == SkillRunPassed {
			n++
		}
	}
	return n
}

func (s *Store) QueryPromotedSkills(ctx context.Context, query string, limit int) ([]Skill, error) {
	if limit <= 0 {
		limit = 5
	}
	if limit > 25 {
		limit = 25
	}
	filter := bson.M{}
	query = strings.TrimSpace(query)
	if query != "" {
		pattern := regexpQuote(query)
		filter = bson.M{
			"$or": []bson.M{
				{"name": bson.M{"$regex": pattern, "$options": "i"}},
				{"content": bson.M{"$regex": pattern, "$options": "i"}},
			},
		}
	}
	opts := options.Find().SetSort(bson.D{{Key: "created_at", Value: -1}}).SetLimit(int64(limit))
	cursor, err := s.db.Collection("skills").Find(ctx, filter, opts)
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)
	var skills []Skill
	if err = cursor.All(ctx, &skills); err != nil {
		return nil, err
	}
	if skills == nil {
		skills = []Skill{}
	}
	return skills, nil
}

func regexpQuote(value string) string {
	replacer := strings.NewReplacer(
		`\`, `\\`, `.`, `\.`, `+`, `\+`, `*`, `\*`, `?`, `\?`,
		`(`, `\(`, `)`, `\)`, `[`, `\[`, `]`, `\]`, `{`, `\{`,
		`}`, `\}`, `|`, `\|`, `^`, `\^`, `$`, `\$`,
	)
	return replacer.Replace(value)
}
