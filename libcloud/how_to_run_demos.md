
  What the demos are

  The demos/ directory contains live integration demos — scripts that connect to real cloud providers (Rackspace, GCE, OpenStack, Aliyun, etc.) and perform real API calls. They are:

  ┌───────────────────────┬────────────────────────────────────────────────────┐
  │         File          │                    Description                     │
  ├───────────────────────┼────────────────────────────────────────────────────┤
  │ compute_demo.py       │ Generic compute demo (any provider via secrets.py) │
  ├───────────────────────┼────────────────────────────────────────────────────┤
  │ gce_demo.py           │ Google Compute Engine full demo (compute, LB, DNS) │
  ├───────────────────────┼────────────────────────────────────────────────────┤
  │ example_openstack.py  │ OpenStack example                                  │
  ├───────────────────────┼────────────────────────────────────────────────────┤
  │ example_aliyun_ecs.py │ Aliyun ECS example                                 │
  ├───────────────────────┼────────────────────────────────────────────────────┤
  │ example_aliyun_oss.py │ Aliyun OSS (storage) example                       │
  ├───────────────────────┼────────────────────────────────────────────────────┤
  │ example_aliyun_slb.py │ Aliyun SLB (load balancer) example                 │
  └───────────────────────┴────────────────────────────────────────────────────┘

  How to run them

  They all require real cloud credentials. There's no local/offline way to run them. Here's the workflow:

  1. Copy the secrets template:
  cp demos/secrets.py-dist demos/secrets.py
  2. Edit demos/secrets.py and fill in credentials for the provider you want to test, e.g.:
  RACKSPACE_PARAMS = ('your_username', 'your_api_key') 
  3. Run a demo from the project root:
  # Generic compute demo (uses secrets.py, defaults to RACKSPACE)
  python demos/compute_demo.py
  
  # GCE demo with all sub-demos
  python demos/gce_demo.py
  
  # Or run specific GCE sub-demos
  python demos/gce_demo.py --compute
  python demos/gce_demo.py --load-balancer
  python demos/gce_demo.py --dns
  
  # Aliyun / OpenStack examples are run directly
  python demos/example_openstack.py

  There are no unit tests for the demos

  There are no automated tests for the demo scripts. The project's test suite (run via tox or pytest) tests the library code itself (drivers, common utilities, etc.) using mocked HTTP fixtures — not the
  demos.

  The demos are intended as manual smoke tests and usage examples for developers who have access to real cloud accounts. They verify that the libcloud drivers work against live APIs, rather than against
  mocked responses.

  If you want to validate the demos without real credentials, your only option is to do a syntax check:

  python -m py_compile demos/compute_demo.py
  python -m py_compile demos/gce_demo.py
  python -m py_compile demos/example_openstack.py
  python -m py_compile demos/example_aliyun_ecs.py
  python -m py_compile demos/example_aliyun_oss.py
  python -m py_compile demos/example_aliyun_slb.py

