terraform {
  # All provider/resource and credential effects are synthetic. terraform_data is built in.
  backend "http" {}

  # TF_ENCRYPTION supplies fixture-only key/method. Never fall back to plaintext.
  encryption {
    state {
      enforced = true
    }
    plan {
      enforced = true
    }
  }
}

variable "synthetic_value" {
  type      = string
  sensitive = true
}

resource "terraform_data" "fixture" {
  input = var.synthetic_value
}

output "synthetic_value" {
  value     = terraform_data.fixture.output
  sensitive = true
}
