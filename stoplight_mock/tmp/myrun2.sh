docker compose up -d --build emulator

# 2. Wait for healthy and run smoke test
docker compose ps
./scripts/smoke-test.sh

# 3. Run Terraform commands
docker compose run --rm -v /home/ubuntu/nutanix_vm/terraform-network:/workspace terraform init
docker compose run --rm  -v /home/ubuntu/nutanix_vm/terraform-network:/workspace terraform plan
docker compose run --rm  -v /home/ubuntu/nutanix_vm/terraform-network:/workspace terraform apply -auto-approve
docker compose run --rm  -v /home/ubuntu/nutanix_vm/terraform-network:/workspace terraform destroy -auto-approve
