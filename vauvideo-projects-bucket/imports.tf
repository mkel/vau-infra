# One-time import of the pre-existing bucket and its sub-resources into this
# root's state. The first plan must show these five imports and NO changes;
# anything else means main.tf has drifted from the live configuration, and
# the plan must not be applied.
#
# After the first successful apply these blocks do nothing and may be
# deleted.

import {
  to = aws_s3_bucket.projects
  id = "vauvideo-projects"
}

import {
  to = aws_s3_bucket_public_access_block.projects
  id = "vauvideo-projects"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.projects
  id = "vauvideo-projects"
}

import {
  to = aws_s3_bucket_cors_configuration.projects
  id = "vauvideo-projects"
}

import {
  to = aws_s3_bucket_policy.projects
  id = "vauvideo-projects"
}
