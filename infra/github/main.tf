# Source-only declaration. No provider/native GitHub operations before a separate phase GO.
terraform {
  required_providers {
    github = {
      source  = "registry.terraform.io/integrations/github"
      version = "= 6.13.0"
    }
  }

  backend "http" {}

  # Native OpenTofu state and plan encryption is mandatory; the key is not source.
  encryption {
    state {
      enforced = true
    }
    plan {
      enforced = true
    }
  }
}

provider "github" {
  owner = "roccho-dev"
}

# Import the existing repository; creation/replacement/destruction is never
# an acceptable substitute. Actual plan delta is limited to description only.
resource "github_repository" "windows" {
  name        = "windows"
  description = ""

  lifecycle {
    prevent_destroy = true
  }
}

import {
  to = github_repository.windows
  id = "windows"
}
