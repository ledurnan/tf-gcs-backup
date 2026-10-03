.PHONY: help test terraform tflint shellcheck ruff pytest bats render ansible-lint

TF_DIRS := modules/project-role modules/backup-target
BUILD := .build
PY := scripts/issue-key scripts/issue-age-key scripts/_keytool.py tests/python

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

test: terraform shellcheck ruff pytest bats render ansible-lint ## Everything CI runs except tflint and gitleaks

terraform: ## Validate and test the modules (mock provider), validate the example
	@set -e; for d in $(TF_DIRS); do \
	  echo "== $$d"; \
	  terraform -chdir=$$d init -input=false -backend=false -no-color >/dev/null; \
	  terraform -chdir=$$d validate -no-color; \
	  terraform -chdir=$$d test -no-color; \
	done
	@echo "== examples/terraform"
	@terraform -chdir=examples/terraform init -input=false -backend=false -no-color >/dev/null
	@terraform -chdir=examples/terraform validate -no-color

tflint: ## Lint the modules and the example
	@set -e; for d in $(TF_DIRS) examples/terraform; do \
	  echo "== $$d"; tflint --chdir=$$d --config=$(CURDIR)/.tflint.hcl; \
	done

shellcheck: ## Lint every shell script
	shellcheck -x ansible/roles/offsite_backup/files/* scripts/restore-test scripts/bootstrap-project scripts/tf-with-identity tests/bats/fakes/* tests/bats/fakes-bootstrap/* tests/gcs-validation/probe

ruff: ## Lint and format-check the Python scripts (settings in .ruff.toml)
	ruff check $(PY)
	ruff format --check $(PY)

pytest: ## Python script tests (issue-age-key, in a pseudo-terminal)
	pytest tests/python

bats: ## Script tests and role validation tests
	bats tests/bats

render: ## Render the role's config and run the backup script on it
	ANSIBLE_ROLES_PATH=ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
	  ansible-playbook tests/ansible/test_render.yml

ansible-lint: ## Build and install the collection, lint the role, tests and examples
	rm -rf $(BUILD) && mkdir -p $(BUILD)
	ansible-galaxy collection build ansible --output-path $(BUILD)
	ansible-galaxy collection install $(BUILD)/*.tar.gz -p $(BUILD)/collections --force
	cd ansible && ansible-lint --offline roles/offsite_backup ../tests/ansible
	ANSIBLE_COLLECTIONS_PATH=$(CURDIR)/$(BUILD)/collections ansible-lint --offline examples/ansible
