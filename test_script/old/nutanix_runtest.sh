
cd ../libcloud/contrib/docker/nutanix
./run_tests.sh
./run_tests.sh integration
NUTANIX_INTEGRATION_TESTS=1 ./run_tests.sh integration

exit


##  Usage
#
#  1. Start the Stoplight emulator:
#
cd stoplight_mock && docker compose up -d
cd ..
#
#  2. Configure credentials (copy from example):
#
cp libcloud_demo/.env.example libcloud_demo/.env
#
#  3. Run scripts via Docker:
#
cd libcloud_demo
docker compose run --rm nutanix vm/list.py
docker compose run --rm nutanix vpc/provision.py --name my-vpc
#
#  4. Full integration test:
#
./test_all.sh
#
#  test_all.sh completed successfully against the running emulator (provision VPC → overlay subnet → VM, list/edit, destroy).
#
#  Note: Storage maps to Nutanix storage containers (cluster-managed pools), not standalone EBS-style volumes. The emulator
#  only supports listing containers; storage/provision.py resolves a container for VM disk placement. Use
#  NUTANIX_HOST=host.docker.internal in .env when running inside Docker.
#
#
#  To resume this session: agent --resume=025d1c32-522e-4437-ab0b-aa23c463ca0f
