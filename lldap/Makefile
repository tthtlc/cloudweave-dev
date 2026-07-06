.PHONY: help up down build bootstrap schema verify create clean

help:           ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

build:          ## Build the lldap-tools image
	docker compose build

up:             ## Start the LLDAP server
	docker compose up -d

down:           ## Stop the LLDAP server (keeps data volume)
	docker compose down

bootstrap: up   ## Start server + create custom attributes (one-shot)
	docker compose --profile bootstrap run --rm --build bootstrap

schema:         ## (Re)apply the custom attribute schema
	docker compose run --rm lldap-tools /scripts/setup-schema.sh

verify:         ## List users and verify the directory over LDAP
	docker compose run --rm lldap-tools /scripts/verify-ldap.py

# create USER EMAIL NAME DEPT ROLE JOBTITLE [PASSWORD]
create:         ## Create a user: make create U=jdoe E=a@b.c N="John Doe" D=Eng R=SWE J="Backend Eng" P=pass
	docker compose run --rm lldap-tools /scripts/create-user.sh \
	    $(U) "$(E)" "$(N)" "$(D)" "$(R)" "$(J)" $(P)

clean:          ## Stop and delete ALL data (users/groups)
	docker compose down -v
