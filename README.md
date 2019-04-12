# Packer Ansible Test

### Dependencies
#### External
1. [docker](https://docs.docker.com)
2. [docker-compose](https://docs.docker.com/compose/)
3. [jq](http://https://stedolan.github.io/jq/)
4. [yq](http://mikefarah.github.io/yq/)

...and if using Packer to build on AWS:

5. [Amazon Web Services Command Line Interface (AWS CLI)](https://docs.aws.amazon.com/cli/latest/userguide/installing.html) -
   only for troubleshooting
6. [saml2aws](https://github.com/Versent/saml2aws) - if using SAML for AWS
   authentication

### About
This is a small application that takes a Packer script and runs it on a Docker
container.  Ansible and the AWS CLI are also installed on the container so the
Packer script can run an Ansible playbook and/or build against AWS, if required.

### Running the program
The following commands should be run from the project root, where
`docker-compose.yml` lives.

#### Execution
Run the program with:

```
./RunPacker.sh -p <script ancestor> [-b] [-d] [-f <script update config file>] [-x <copy exclusions file>]
```

...where:
 
* *-p* specifies the ancestor path of the Packer script and its dependencies.
  All children of this directory are copied to the `build/packer-project`
  directory and mounted as a volume in the Packer container.
* *-b* (optional) specifies the container should be brought down and rebuilt.
  This should be used when the Docker image (environment or arguments) needs to
  change.
* *-d* (optional) specifies Packer is to be run in debug mode.  This will stop
  Packer being executed when the container starts - you will need to log in to
  the container and run DebugPacker.sh to step through the Packer script.
* *-f* (optional) specifies a YAML file that describes how to update settings in
  the Packer script.  This is used to make alterations on the **copied** script,
  which can be useful for testing.  See the
  [Packer script update configuration](#packer-script-update-configuration)
  section for details.
* *-x* (optional) specifies a plain text file containing a list of directories
  and/or files (one per line) that should **not** be copied over to the
  container.  The paths for these are relative to the ancestor path specified
  with the *-p* flag.

**Note:** The Packer script itself is specified as an environment variable in
the `docker-compose.yml` file.  The path, like those specified in the copy
exclusion list (*-x* flag), is relative to the ancestor path specified with the
*-p* flag.
 
#### Checking logs  
The *packer-ansible* container will not display output from the script
execution, which usually takes a while to run.  The following command allows you
to monitor Packer's progress:

```
docker logs packer-ansible --follow
```

...use `Ctrl+C` to escape when done.

#### Inspecting the container
You can review the environment in the *packer-ansible* container by logging in
to it with the following command:

```
docker exec -it packer-ansible /usr/bin/env bash
```

Type `exit` at the prompt to get out of the container.

**Note:** If you change the container name, you will need to alter the above
commands as discussed in the [Docker configuration](#docker-configuration)
section.

### Clean up
The container can be shut down from the project root with:

```
docker-compose down
```

The Docker container and image from which the container is built can all be
removed in one go with:

```
./Cleanup.sh
```

### Docker configuration
The following items are set in the `docker-compose.yml` file:

* `BASE_IMAGE` - The base Docker Linux image, set to `hashicorp/packer:latest`.
  If not set, the `Dockerfile` specifies this as the default.
* `container_name` - Set to *packer-ansible*, but this can be altered if another
  name is preferred.
* `image` - Set to *packer_ansible_image*, but again can be altered if another
  name is preferred.
* `PACKER_SCRIPT` - An environment variable for the *packer-ansible*
  container you **must** replace with the path to your Packer script (relative
  to the ancestor directory specified on the `./RunPacker.sh` command line).
* `USER_ID` & `USER_NAME` - Environment variables set by the `./RunPacker.sh`
  script to replicate your user name and ID in the container.  The `USER`
  environment variable is required by Packer to determine the running user.
  These items are best left alone.
* `volumes` - You should not need to change the Packer copy mapping for the
  container.  If you do so, you will need to change `RunPacker.sh`,
  `ErrorHandling.sh` and `build/packer-ansible/Dockerfile` to match.  The `.aws`
  and `.saml2aws` mappings should point to your SAML/AWS credentials files and
  directories.  These can be removed if not using SAML or AWS.  Otherwise, you
  should authenticate/start an AWS session with the *default* profile **before**
  running the container.

There are other items set in this file which should not be changed.  Alter them
at your own risk.

### Packer script update configuration
If used, the script update configuration describes how to alter the Packer
build script.  A YAML file, the following options are currently supported, none
of which is mandatory:
* `build_tag` - Sets the build tag for the generated Amazon Machine Image (AMI).
* `increment_tag` - Set to `true` or `false`.  If `true` and the `build_tag`
                    ends in a number, this indicates the number should be
                    incremented each time the program runs.
* `keep_ami_users` - Set to `true` or `false`.  If the build script includes an
                     `ami_users` list, setting this value to `false` will remove
                     it.
* `regions` - Lists the regions in which an AMI should be built.
* `subnets` - Lists the `subnet_id` to use in each region (one per region).

**Note:**  The first time the program is run, this file is backed up to 
preserve the original `build_tag` value.  The backup file has the same name,
with `.orig` appended.  Due to limitations in `yq`, any comments in this file
will be lost and must be restored from the backed up original if required.

### Troubleshooting
If you see 404 errors when trying to run the program, you need to review the
message carefully.  If it mentions `Operation not permitted`, check your AWS
connection **outside** the container by running the following:
```
aws s3api list-buckets --query "Buckets[].Name"
```
**Things to note:**
* the AWS CLI must be installed locally to run the above command
* you must use the **default** AWS profile, as this is what Packer uses when
  running a build
* ensure the account and region nominated for the profile are correct
