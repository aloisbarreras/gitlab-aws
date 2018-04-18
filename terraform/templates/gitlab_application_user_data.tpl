#cloud-config

mounts:
  - [ "${nfs_server_private_ip}:/gitlab-data", /gitlab-data, nfs4, "defaults,soft,rsize=1048576,wsize=1048576,noatime,lookupcache=positive", "0", "2" ]
  - [ /gitlab-data/git-data, /var/opt/gitlab/git-data, none, bind, "0", "0" ]
  - [ /gitlab-data/.ssh, /var/opt/gitlab/.ssh, none, bind, "0", "0" ]
  - [ /gitlab-data/uploads, /var/opt/gitlab/gitlab-rails/uploads, none, bind, "0", "0" ]
  - [ /gitlab-data/shared, /var/opt/gitlab/gitlab-rails/shared, none, bind, "0", "0" ]
  - [ /gitlab-data/builds, /var/opt/gitlab/gitlab-ci/builds, none, bind, "0", "0" ]

write_files:
  - content: |
      # Prevent GitLab from starting if NFS data mounts are not available
      high_availability['mountpoint'] = ['/var/opt/gitlab/git-data', '/var/opt/gitlab/.ssh', '/var/opt/gitlab/gitlab-rails/uploads', '/var/opt/gitlab/gitlab-rails/shared', '/var/opt/gitlab/gitlab-ci/builds']
      # Disabe built-in postgres and redis
      postgresql['enable'] = false
      redis['enable'] = false
      # External postgres settings
      gitlab_rails['db_adapter'] = "postgresql"
      gitlab_rails['db_encoding'] = "unicode"
      gitlab_rails['db_database'] = "${postgres_database}"
      gitlab_rails['db_username'] = "${postgres_username}"
      gitlab_rails['db_password'] = "${postgres_password}"
      gitlab_rails['db_host'] = "${postgres_endpoint}"
      gitlab_rails['db_port'] = 5432
      gitlab_rails['auto_migrate'] = false
      # External redis settings
      gitlab_rails['redis_host'] = "${redis_endpoint}"
      gitlab_rails['redis_port'] = 6379
      # Whitelist VPC cidr for access to health checks
      gitlab_rails['monitoring_whitelist'] = ['${cidr}']
    path: /etc/gitlab/gitlab.rb
    permissions: '0600'

runcmd:
  - [ gitlab-ctl, reconfigure ]

output: {all: '| tee -a /var/log/alchemy-cloud-init-output.log'}