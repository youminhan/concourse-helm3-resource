FROM alpine/helm:3.8.0
LABEL maintainer "Yann David (@Typositoire) <davidyann88@gmail>"

RUN apk add --update --upgrade --no-cache jq bash curl git

ARG KUBERNETES_VERSION=1.22.2
RUN curl -sL -o /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl; \
  chmod +x /usr/local/bin/kubectl

ADD assets /opt/resource
RUN chmod +x /opt/resource/*

ARG HELM_PLUGINS="https://github.com/helm/helm-2to3"
RUN for i in $(echo $HELM_PLUGINS | xargs -n1); do helm plugin install $i; done

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
