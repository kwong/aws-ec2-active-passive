terraform {
  required_version = ">=1.1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.18.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.3.1"
    }
  }
}
