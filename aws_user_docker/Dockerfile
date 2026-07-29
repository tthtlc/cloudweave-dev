FROM alpine:3.21

RUN apk add --no-cache \
    aws-cli \
    jq \
    bash \
    coreutils

# The host's ~/.aws directory is mounted read-only so the container can
# inherit the admin session.  Credential output goes to /aws_output on a
# separate host-mounted volume so it survives container teardown.
RUN mkdir -p /aws_output

COPY create_ec2_user.sh /usr/local/bin/create_ec2_user.sh
RUN chmod +x /usr/local/bin/create_ec2_user.sh

ENTRYPOINT ["/usr/local/bin/create_ec2_user.sh"]
