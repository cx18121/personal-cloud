#!/usr/bin/env bash
set -euo pipefail

: "${AWS_PROFILE:?AWS_PROFILE must name the personal cloud profile}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${TF_VAR_account_id:?TF_VAR_account_id must be set}"

if [[ "$AWS_PROFILE" != "personal-cloud-admin" ]]; then
  printf 'Refusing to run with AWS profile %s\n' "$AWS_PROFILE" >&2
  exit 1
fi

if [[ "$AWS_REGION" != "us-east-1" ]]; then
  printf 'Refusing to run in AWS region %s\n' "$AWS_REGION" >&2
  exit 1
fi

actual_account=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
if [[ "$actual_account" != "$TF_VAR_account_id" ]]; then
  printf 'Refusing to run in AWS account ending %s\n' "${actual_account: -4}" >&2
  exit 1
fi

printf 'Personal cloud account verified in %s.\n' "$AWS_REGION"
