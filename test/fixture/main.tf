variable "message" {
  type    = string
  default = "fixture-default"
}

resource "terraform_data" "echo" {
  input = var.message
}

output "message" {
  value = terraform_data.echo.output
}

output "secret" {
  value     = "s3cr3t"
  sensitive = true
}
