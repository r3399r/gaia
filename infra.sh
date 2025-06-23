#!/bin/bash
set -e

env=$1
project=gaia

echo ====================================================================================
echo env: $env
echo project: $project
echo ====================================================================================

echo deploy AWS infrastructure...
aws cloudformation package --template-file aws/template.yaml --output-template-file packaged.yaml --s3-bucket y-cf-midway-ap-east-2
aws cloudformation deploy --template-file packaged.yaml --stack-name $project-$env-stack --parameter-overrides TargetEnvr=$env --no-fail-on-empty-changeset --s3-bucket y-cf-midway-ap-east-2 --capabilities CAPABILITY_NAMED_IAM
echo ====================================================================================