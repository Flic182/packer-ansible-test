ARG BASE_IMAGE=hashicorp/packer:latest
FROM $BASE_IMAGE

# Must put these ARGs here.  If ahead of the FROM, they will be wiped clean!
ARG USER_ID
ARG USER_NAME

RUN apk --no-cache add curl dbus-x11 gnome-keyring openssh-client libsecret \
                       python3 py-boto py-dateutil py-httplib2 py-jinja2 \
                       py-paramiko py-pip py-setuptools py-yaml shadow tar && \
    python3 -m ensurepip && rm -r /usr/lib/python*/ensurepip && \
    pip3 install --upgrade pip && pip3 install awscli --upgrade --user && \
    rm -rf /var/cache/apk/*

RUN adduser -Du $USER_ID $USER_NAME

RUN mkdir -p /etc/ansible/
COPY hosts /etc/ansible

RUN pip3 install ansible && \
    rm -fr ansible.tar.gz /ansible/docs /ansible/examples /ansible/packaging

COPY *.sh /usr/local/bin/
RUN chmod u+x /usr/local/bin/*.sh

ENTRYPOINT ["Entrypoint.sh"]

CMD ["/bin/sh"]
