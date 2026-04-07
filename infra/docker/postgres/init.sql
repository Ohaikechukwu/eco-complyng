-- Public schema: org registry + system checklist templates
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS orgs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  schema_name TEXT NOT NULL UNIQUE,
  email       TEXT NOT NULL UNIQUE,
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS checklist_templates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  description TEXT,
  is_system   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS checklist_template_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id UUID NOT NULL REFERENCES checklist_templates(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  sort_order  INT DEFAULT 0
);

-- Seed system checklist templates from uploaded domain documents
INSERT INTO checklist_templates (id, name, description, is_system) VALUES
  ('00000000-0000-0000-0000-000000000001', 'GBV Checklist', 'Gender-Based Violence compliance checklist', TRUE),
  ('00000000-0000-0000-0000-000000000002', 'Environment/HSE Checklist', 'Health, Safety and Environment checklist', TRUE),
  ('00000000-0000-0000-0000-000000000003', 'Social Safeguard Checklist', 'Social safeguard compliance checklist', TRUE);

-- GBV items
INSERT INTO checklist_template_items (template_id, description, sort_order) VALUES
  ('00000000-0000-0000-0000-000000000001', 'Qualified GBV specialist in supervision consultant team', 1),
  ('00000000-0000-0000-0000-000000000001', 'Qualified Social/GBV officer in Contractor''s team', 2),
  ('00000000-0000-0000-0000-000000000001', 'GBV trainings and CoC sensitization conducted for the SPIU', 3),
  ('00000000-0000-0000-0000-000000000001', 'GBV training and CoC sensitization conducted for contractors workers and Supervision Consultants', 4),
  ('00000000-0000-0000-0000-000000000001', 'Signed COCs for SPIU staff', 5),
  ('00000000-0000-0000-0000-000000000001', 'Signed CoCs for Supervision Consultants team', 6),
  ('00000000-0000-0000-0000-000000000001', 'Signed CoCs for Contractors management and workers', 7),
  ('00000000-0000-0000-0000-000000000001', 'Presence of GBV key messaging/posters/fliers on-site', 8),
  ('00000000-0000-0000-0000-000000000001', 'Provision of separate toilet facilities for male and female adequately labelled with internal locks', 9),
  ('00000000-0000-0000-0000-000000000001', 'Location of contractor''s camp in compliance with ESMP requirements', 10),
  ('00000000-0000-0000-0000-000000000001', 'Proper lighting around worksite and contractors'' camps', 11),
  ('00000000-0000-0000-0000-000000000001', 'Established GBV complaints mechanism', 12),
  ('00000000-0000-0000-0000-000000000001', 'GBV Mapping of service providers available', 13),
  ('00000000-0000-0000-0000-000000000001', 'GBV Intermediary Service Provider available', 14),
  ('00000000-0000-0000-0000-000000000001', 'Progress and implementation of the GBV Action Plan & Response Framework', 15);

-- HSE items
INSERT INTO checklist_template_items (template_id, description, sort_order) VALUES
  ('00000000-0000-0000-0000-000000000002', 'Qualified Environment/HSE Specialist on Supervision Consultant team', 1),
  ('00000000-0000-0000-0000-000000000002', 'Qualified Environment/HSE Specialist on Contractor team', 2),
  ('00000000-0000-0000-0000-000000000002', 'Presence of Caution Signage, Flag Men, Barricade, Flood Lights on-site', 3),
  ('00000000-0000-0000-0000-000000000002', 'Compliance to Burrow Pit Management Plan', 4),
  ('00000000-0000-0000-0000-000000000002', 'Presence of Leakages & Spills at staging areas', 5),
  ('00000000-0000-0000-0000-000000000002', 'Inspecting the RoW for safety mechanisms at setback, T-Junctions, Starting and End Point', 6),
  ('00000000-0000-0000-0000-000000000002', 'Appropriate safety for drainages and Culverts along the route', 7),
  ('00000000-0000-0000-0000-000000000002', 'Safety of Camp Sites and provision of workers facilities', 8),
  ('00000000-0000-0000-0000-000000000002', 'Safety of Staging Areas, good housekeeping, restricted access', 9),
  ('00000000-0000-0000-0000-000000000002', 'PPE Use and Enforcement', 10),
  ('00000000-0000-0000-0000-000000000002', 'Creation of access and alternative routes', 11),
  ('00000000-0000-0000-0000-000000000002', 'Presence of Contractors HSE Plan & training plan', 12),
  ('00000000-0000-0000-0000-000000000002', 'Presence of Contractors Burrow Pit Management Plan', 13),
  ('00000000-0000-0000-0000-000000000002', 'Presence of Contractors Waste Management Plan', 14),
  ('00000000-0000-0000-0000-000000000002', 'Evidence of Waste Management Implementation', 15),
  ('00000000-0000-0000-0000-000000000002', 'Evidence of Burrow pit management implementation', 16),
  ('00000000-0000-0000-0000-000000000002', 'Evidence of Traffic Management Implementation', 17),
  ('00000000-0000-0000-0000-000000000002', 'Evidence of OHS/HSE Management Implementation', 18),
  ('00000000-0000-0000-0000-000000000002', 'Evidence of Road Safety Management Implementation', 19),
  ('00000000-0000-0000-0000-000000000002', 'Dust Suppression & Management', 20),
  ('00000000-0000-0000-0000-000000000002', 'Source of energy & power', 21),
  ('00000000-0000-0000-0000-000000000002', 'Source of water for construction, staging area and campsite', 22),
  ('00000000-0000-0000-0000-000000000002', 'Evidence of Drivers Training and Tool Box Meeting', 23),
  ('00000000-0000-0000-0000-000000000002', 'Emergency Response & Safety Procedure', 24),
  ('00000000-0000-0000-0000-000000000002', 'Presence of well-stocked First Aid Box and First Aider', 25),
  ('00000000-0000-0000-0000-000000000002', 'HSE Statistics Board on-site', 26),
  ('00000000-0000-0000-0000-000000000002', 'Visitors protocol and management on-site', 27),
  ('00000000-0000-0000-0000-000000000002', 'Safety Equipment (Fire Extinguisher)', 28),
  ('00000000-0000-0000-0000-000000000002', 'Security Equipment', 29),
  ('00000000-0000-0000-0000-000000000002', 'Presence of list of clinics/hospitals to be used by workers', 30);

-- Social Safeguard items
INSERT INTO checklist_template_items (template_id, description, sort_order) VALUES
  ('00000000-0000-0000-0000-000000000003', 'Hours of Operation', 1),
  ('00000000-0000-0000-0000-000000000003', 'RAP Implementation', 2),
  ('00000000-0000-0000-0000-000000000003', 'Security Management Protocol Implementation', 3),
  ('00000000-0000-0000-0000-000000000003', 'Grievances Redress Mechanism', 4),
  ('00000000-0000-0000-0000-000000000003', 'Stakeholders Engagement & Consultation status', 5),
  ('00000000-0000-0000-0000-000000000003', 'Adequacy of Workers Welfare (Toilets, Accommodations, Water, Light)', 6);
