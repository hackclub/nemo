ALTER TABLE api.consent ADD COLUMN id bigserial;

ALTER TABLE api.consent ADD CONSTRAINT consent_pkey PRIMARY KEY (id);
