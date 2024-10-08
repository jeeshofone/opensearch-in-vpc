/*
Before creating the first OpenSearch cluster, ensure the service linked role exists.
If it doesn't, it can be created using following AWS CLI command:
$ aws iam create-service-linked-role --aws-service-name es.amazonaws.com
*/
resource "null_resource" "aos_service_linked_role" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-COMMAND
      aws iam create-service-linked-role --aws-service-name es.amazonaws.com
    COMMAND
    on_failure = continue
  }
}

data "aws_iam_role" "aos_service_linked_role" {
  name = "AWSServiceRoleForAmazonElasticsearchService"

  depends_on = [
    null_resource.aos_service_linked_role
  ]
}

resource "aws_opensearch_vpc_endpoint" "aos_vpc_endpoint" {
  domain_arn = aws_opensearch_domain.aos.arn
  vpc_options {
    subnet_ids         = var.aos_domain_subnet_ids
    security_group_ids = [aws_security_group.opensearch.id]
  }
}

resource "aws_opensearch_domain" "aos" {
  domain_name    = var.aos_domain_name
  engine_version = var.opensearch_version

  cluster_config {
    instance_count           = var.aos_data_instance_count
    instance_type            = var.aos_data_instance_type
    dedicated_master_enabled = var.aos_master_instance_count > 0
    dedicated_master_count   = var.aos_master_instance_count
    dedicated_master_type    = var.aos_master_instance_type
    zone_awareness_enabled   = var.aos_zone_awareness_enabled
    warm_enabled             = false
  }

  ebs_options {
    ebs_enabled = true
    volume_size = var.aos_data_instance_storage
    volume_type = "gp2"
  }

  vpc_options {
    subnet_ids         = var.aos_domain_subnet_ids
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled = var.aos_encrypt_at_rest
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false
    master_user_options {
      master_user_arn = aws_iam_role.aos_cognito_authenticated.arn
    }
  }

  access_policies = data.aws_iam_policy_document.aos_access_policies.json

  cognito_options {
    enabled          = true
    user_pool_id     = aws_cognito_user_pool.aos_pool.id
    identity_pool_id = aws_cognito_identity_pool.aos_pool.id
    role_arn         = aws_iam_role.cognito_for_aos.arn
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_logs.arn
    log_type                 = "INDEX_SLOW_LOGS"
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_logs.arn
    log_type                 = "SEARCH_SLOW_LOGS"
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_logs.arn
    log_type                 = "ES_APPLICATION_LOGS"
  }

  tags = var.tags

  depends_on = [data.aws_iam_role.aos_service_linked_role]
}

resource "null_resource" "update_cognito_client" {
  triggers = {
    domain_endpoint = aws_opensearch_domain.aos.endpoint
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-COMMAND
      sleep 10 # Give some time for the endpoint to become available
      aws cognito-idp update-user-pool-client \
        --user-pool-id ${aws_cognito_user_pool.aos_pool.id} \
        --client-id ${aws_cognito_user_pool_client.aos_user_pool_client.id} \
        --supported-identity-providers "COGNITO" \
        --callback-urls "https://${aws_opensearch_domain.aos.dashboard_endpoint}/_dashboards" \
        --logout-urls "https://${aws_opensearch_domain.aos.dashboard_endpoint}/_dashboards" \
        --allowed-o-auth-flows "code" \
        --allowed-o-auth-scopes "email" "openid" \
        --allowed-o-auth-flows-user-pool-client \
        --region ${local.aws_region}
    COMMAND
  }

  depends_on = [aws_opensearch_domain.aos]
}

data "aws_iam_policy_document" "aos_access_policies" {
  statement {
    effect = "Allow"
    principals {
      type = "AWS"
      identifiers = [aws_iam_role.aos_cognito_authenticated.arn]
    }
    actions = [
      "es:ESHttp*"
    ]
    resources = [
      "arn:aws:es:${local.aws_region}:${local.aws_account_id}:domain/${var.aos_domain_name}/*"
    ]
  }
}

####################################################################################################
# Logs
####################################################################################################

resource "aws_cloudwatch_log_group" "opensearch_logs" {
  name = "opensearch/${var.aos_domain_name}"
}

resource "aws_cloudwatch_log_resource_policy" "opensearch_logs" {
  policy_name = "opensearch-${var.aos_domain_name}"
  policy_document = data.aws_iam_policy_document.opensearch_logs.json
}

data "aws_iam_policy_document" "opensearch_logs" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = ["es.amazonaws.com"]
    }
    actions = [
      "logs:PutLogEvents",
      "logs:PutLogEventsBatch",
      "logs:CreateLogStream",
    ]
    resources = [
      "arn:aws:logs:*"
    ]
  }
}
