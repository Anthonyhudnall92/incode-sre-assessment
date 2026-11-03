#!/usr/bin/env bash
# Prove what the CI roles may and may not do. Read-only: uses the IAM
# policy simulator, never performs the actions.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export AWS_PROFILE="${AWS_PROFILE:-incode}"

ACCT=$(aws sts get-caller-identity --query Account --output text)
APPLY="arn:aws:iam::${ACCT}:role/sre-demo-github-apply"
PLAN="arn:aws:iam::${ACCT}:role/sre-demo-github-plan"
BOUNDARY="arn:aws:iam::${ACCT}:policy/sre-demo-workload-boundary"
STATEKEY=$(terraform -chdir=bootstrap output -raw state_kms_key_arn)
BUCKET="arn:aws:s3:::$(terraform -chdir=bootstrap output -raw state_bucket)"
ZONE="arn:aws:route53:::hostedzone/$(terraform -chdir=bootstrap output -raw dns_zone_id)"
B="ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${BOUNDARY},ContextKeyType=string"
PASS=0; FAIL=0

sim() { # role expected action resource context description
  local ctx=() entries=()
  # Several context entries may be given, separated by spaces.
  [[ -n "$5" ]] && read -ra entries <<<"$5" && ctx=(--context-entries "${entries[@]}")
  local got
  got=$(aws iam simulate-principal-policy --policy-source-arn "$1" --action-names "$3" \
    --resource-arns "$4" ${ctx[@]+"${ctx[@]}"} --query 'EvaluationResults[0].EvalDecision' --output text 2>&1)
  local verdict=FAIL
  if [[ "$2" == allowed && "$got" == allowed ]] || [[ "$2" == denied && ( "$got" == implicitDeny || "$got" == explicitDeny ) ]]; then
    verdict=ok; PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  printf "%-4s %-5s %-34s %-13s %s\n" "$verdict" "${1##*-}" "$3" "$got" "$6"
}

sim "$APPLY" allowed iam:CreateRole "arn:aws:iam::${ACCT}:role/sre-demo-x" "$B" "stack role WITH the boundary"
sim "$APPLY" denied  iam:CreateRole "arn:aws:iam::${ACCT}:role/sre-demo-x" "" "stack role WITHOUT the boundary"
sim "$APPLY" denied  iam:CreateRole "arn:aws:iam::${ACCT}:role/other-x" "$B" "role outside sre-demo-*"
sim "$APPLY" denied  iam:UpdateAssumeRolePolicy "$APPLY" "" "edit its own trust policy"
sim "$APPLY" denied  iam:AttachRolePolicy "$APPLY" "$B" "attach more policies to itself"
sim "$APPLY" denied  iam:CreatePolicyVersion "$BOUNDARY" "" "rewrite the boundary"
sim "$APPLY" denied  iam:DeleteRolePermissionsBoundary "arn:aws:iam::${ACCT}:role/sre-demo-node" "" "strip a role's boundary"
sim "$APPLY" denied  iam:CreateUser "arn:aws:iam::${ACCT}:user/x" "" "create an IAM user"
sim "$APPLY" allowed kms:Decrypt "$STATEKEY" "" "read state"
sim "$APPLY" denied  kms:ScheduleKeyDeletion "$STATEKEY" "" "delete the state key"
sim "$APPLY" denied  kms:PutKeyPolicy "$STATEKEY" "" "change the state key policy"
sim "$APPLY" allowed s3:PutObject "${BUCKET}/sre-demo/main.tfstate" "" "write main stack state"
sim "$APPLY" denied  s3:PutObject "${BUCKET}/other/main.tfstate" "" "write any other state file"
sim "$APPLY" denied  s3:DeleteBucket "$BUCKET" "" "delete the state bucket"
sim "$APPLY" denied  route53:DeleteHostedZone "$ZONE" "" "delete the DNS zone"
sim "$APPLY" allowed route53:ChangeResourceRecordSets "$ZONE" "" "manage records in the zone"
sim "$APPLY" denied  ec2:RunInstances "*" "" "launch arbitrary instances"
sim "$APPLY" denied  secretsmanager:GetSecretValue "arn:aws:secretsmanager:us-east-1:${ACCT}:secret:rds!x" "" "read the DB password"
sim "$PLAN"  allowed ec2:DescribeVpcs "*" "" "read for plan"
sim "$PLAN"  denied  ec2:CreateVpc "*" "" "write anything"
sim "$PLAN"  denied  s3:PutObject "${BUCKET}/sre-demo/main.tfstate" "" "overwrite state"
sim "$PLAN"  allowed s3:PutObject "${BUCKET}/sre-demo/main.tfstate.tflock" "" "take the state lock"
sim "$PLAN"  denied  secretsmanager:GetSecretValue "arn:aws:secretsmanager:us-east-1:${ACCT}:secret:rds!x" "" "read the DB password"
R="ContextKeyName=aws:RequestedRegion,ContextKeyValues=us-east-1,ContextKeyType=string"
T="ContextKeyName=aws:RequestTag/Stack,ContextKeyValues=main,ContextKeyType=string"
RT="ContextKeyName=aws:ResourceTag/Stack,ContextKeyValues=main,ContextKeyType=string"
sim "$APPLY" allowed ec2:CreateLaunchTemplateVersion "arn:aws:ec2:us-east-1:${ACCT}:launch-template/lt-x" "$R" "node group update: new launch template version"
sim "$APPLY" allowed eks:UpdateNodegroupVersion "arn:aws:eks:us-east-1:${ACCT}:nodegroup/sre-demo/x/y" "" "node group update: roll the nodes"
TYPE="ContextKeyName=ec2:InstanceType,ContextKeyValues=t3.micro,ContextKeyType=string"
BIG="ContextKeyName=ec2:InstanceType,ContextKeyValues=m5.24xlarge,ContextKeyType=string"
sim "$APPLY" allowed ec2:RunInstances "arn:aws:ec2:us-east-1:${ACCT}:instance/*" "$T $TYPE" "launch the stack-tagged t3.micro jump host"
sim "$APPLY" denied  ec2:RunInstances "arn:aws:ec2:us-east-1:${ACCT}:instance/*" "$T $BIG" "launch a big instance, even tagged"
sim "$APPLY" denied  ec2:RunInstances "arn:aws:ec2:us-east-1:${ACCT}:instance/*" "" "launch an untagged instance"
LTARN="arn:aws:ec2:us-east-1:${ACCT}:launch-template/lt-x"
NODE="ContextKeyName=ec2:InstanceType,ContextKeyValues=t3.medium,ContextKeyType=string"
VIALT="ContextKeyName=ec2:LaunchTemplate,ContextKeyValues=${LTARN},ContextKeyType=string"
sim "$APPLY" allowed ec2:RunInstances "arn:aws:ec2:us-east-1:${ACCT}:instance/*" "$NODE $VIALT" "node group dry run: t3.medium from a launch template"
sim "$APPLY" denied  ec2:RunInstances "arn:aws:ec2:us-east-1:${ACCT}:instance/*" "$NODE" "t3.medium without a launch template"
sim "$APPLY" allowed ec2:RunInstances "$LTARN" "$RT" "use the stack-tagged launch template"
sim "$APPLY" denied  ec2:RunInstances "$LTARN" "" "use an untagged launch template"
TAGMAIN="ContextKeyName=aws:RequestTag/Stack,ContextKeyValues=main,ContextKeyType=string"
TOLAMBDA="ContextKeyName=iam:PassedToService,ContextKeyValues=lambda.amazonaws.com,ContextKeyType=string"
STATEBUCKET="arn:aws:s3:::$(terraform -chdir=bootstrap output -raw state_bucket)"
sim "$APPLY" allowed synthetics:CreateCanary "*" "$TAGMAIN" "create a stack-tagged canary"
sim "$APPLY" denied  synthetics:CreateCanary "*" "" "create an untagged canary"
sim "$APPLY" allowed lambda:CreateFunction "arn:aws:lambda:us-east-1:${ACCT}:function:cwsyn-sre-demo-x" "" "Synthetics creates the canary function"
sim "$APPLY" denied  lambda:CreateFunction "arn:aws:lambda:us-east-1:${ACCT}:function:anything" "" "create any other Lambda"
sim "$APPLY" allowed s3:CreateBucket "arn:aws:s3:::sre-demo-canary-${ACCT}" "" "create the canary bucket"
sim "$APPLY" allowed s3:PutBucketPolicy "arn:aws:s3:::sre-demo-alb-logs-${ACCT}" "" "set the ALB log bucket's policy"
sim "$APPLY" denied  s3:CreateBucket "arn:aws:s3:::someone-elses-bucket" "" "create any other bucket"
sim "$APPLY" denied  s3:DeleteBucket "$STATEBUCKET" "" "delete the state bucket"
sim "$APPLY" allowed aps:CreateWorkspace "*" "$TAGMAIN" "create a stack-tagged Prometheus"
sim "$APPLY" allowed iam:PassRole "arn:aws:iam::${ACCT}:role/sre-demo-canary" "$TOLAMBDA" "pass the canary role to Lambda"
TOSYN="ContextKeyName=iam:PassedToService,ContextKeyValues=synthetics.amazonaws.com,ContextKeyType=string"
sim "$APPLY" allowed iam:PassRole "arn:aws:iam::${ACCT}:role/sre-demo-canary" "$TOSYN" "pass the canary role to Synthetics (CreateCanary)"
sim "$APPLY" allowed ec2:MonitorInstances "arn:aws:ec2:us-east-1:${ACCT}:instance/i-x" "$RT" "detailed monitoring on stack instances"

echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
