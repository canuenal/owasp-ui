#-------------stage1 - create app (django4 and nodejs16)------------------------------
FROM nikolaik/python-nodejs:python3.11-nodejs16-slim AS base
FROM base AS stage1
WORKDIR /app
RUN apt-get -y update && apt-get -y install --no-install-recommends \
    gcc build-essential dnsutils libpq-dev postgresql-client xmlsec1 git uuid-runtime libcurl4-openssl-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists && true
COPY requirements.txt ./

# CPUCOUNT=1 is needed, otherwise the wheel for uwsgi won't always be build succesfully
RUN CPUCOUNT=1 pip3 wheel --wheel-dir=/tmp/wheels -r ./requirements.txt
#------------stage2 - create app----------------------------------------------------------
FROM base AS stage2
WORKDIR /app
ARG uid=1001
ARG gid=1337
ARG appuser=owasp-ui
ENV appuser ${appuser}
RUN apt-get -y update && \
    # ugly fix to install postgresql-client without errors
    mkdir -p /usr/share/man/man1 /usr/share/man/man7 && \
    apt-get -y install --no-install-recommends \
    # libopenjp2-7 libjpeg62 libtiff5 are required by the pillow package
    libopenjp2-7 libjpeg62 libtiff5 dnsutils xmlsec1 git uuid-runtime libpq-dev postgresql-client libcurl4-openssl-dev  && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists &&  true
COPY --link --from=build /tmp/wheels /tmp/wheels
COPY requirements.txt ./
RUN export PYCURL_SSL_LIBRARY=openssl && \
    pip3 install --no-cache-dir --no-index  --find-links=/tmp/wheels -r ./requirements.txt
COPY wsgi.py manage.py docker/unit-tests.sh ./
COPY dojo/ ./owasp-ui/
# Add extra fixtures to docker image which are loaded by the initializer
COPY docker/extra_fixtures/* /app/owasp-ui/fixtures/
COPY tests/ ./tests/
RUN rm -f /readme.txt && \
    rm -f dojo/fixtures/readme.txt && mkdir -p owasp-ui/migrations && chmod g=u owasp-ui/migrations && true
USER root
RUN \
    addgroup --gid ${gid} ${appuser} && \
    adduser --system --no-create-home --disabled-password --gecos '' --uid ${uid} --gid ${gid} ${appuser} && \
    chown -R root:root /app && chmod -R u+rwX,go+rX,go-w /app && \
    # Allow for bind mounting local_settings.py and other setting overrides
    chown -R root:${appuser} /app/owasp-ui/settings && chmod -R 775 /app/owasp-ui/settings && \
    mkdir /var/run/${appuser} && \
    chown ${appuser} /var/run/${appuser} && chmod g=u /var/run/${appuser} && chmod 775 /*.sh && \
    mkdir -p media/threat && chown -R ${uid} media
USER ${uid}
ENV \
    # Only variables that are not defined in settings.dist.py
    DD_ADMIN_USER=admin \
    DD_ADMIN_MAIL=admin@defectdojo.local \
    DD_ADMIN_PASSWORD='' \
    DD_ADMIN_FIRST_NAME=Admin \
    DD_ADMIN_LAST_NAME=User \
    DD_CELERY_LOG_LEVEL="INFO" \
    DD_CELERY_WORKER_POOL_TYPE="solo" \
    # Enable prefork and options below to ramp-up celeryworker performance. Presets should work fine for a machine with 8GB of RAM, while still leaving room.
    # See https://docs.celeryproject.org/en/stable/userguide/workers.html#id12 for more details
    # DD_CELERY_WORKER_POOL_TYPE="prefork" \
    # DD_CELERY_WORKER_AUTOSCALE_MIN="2" \
    # DD_CELERY_WORKER_AUTOSCALE_MAX="8" \
    # DD_CELERY_WORKER_CONCURRENCY="8" \
    # DD_CELERY_WORKER_PREFETCH_MULTIPLIER="128" \
    DD_INITIALIZE=true \
    DD_UWSGI_MODE="socket" \
    DD_UWSGI_ENDPOINT="0.0.0.0:3031" \
    DD_UWSGI_NUM_OF_PROCESSES="2" \
    DD_UWSGI_NUM_OF_THREADS="2"

#------------stage3 - run unittestss--------------------------------------------------------
FROM stage2 AS stage3
COPY unittests/ ./unittests/

#------------stage4 - run nodejs part--------------------------------------------------------
FROM stage2 AS stage4
WORKDIR /app
ENV  node="nodejs"
COPY components/ ./components/
RUN  cd components &&  yarn

COPY --link --from=stage2 /app/ /app/
RUN env DD_SECRET_KEY='.' python3 manage.py collectstatic --noinput && true
#------------stage5 - create nginx----------------------------------------------------------
FROM stage4 AS stage5
USER root
WORKDIR /app
RUN apt update && apt upgrade -y && \
    apt install nginx -y procps -y gettext-base -y && \
    rm -rf /var/lib/apt/lists/* && \
    apk add --no-cache openssl && \
    chmod -R g=u /var/cache/nginx && \
    mkdir /var/run/openas && \
    chmod -R g=u /var/run/owasp-ui && \
    mkdir -p /etc/nginx/ssl && \
    chmod -R g=u /etc/nginx && \
    true
ENV \
    DD_UWSGI_PASS="uwsgi_server" \
    DD_UWSGI_HOST="uwsgi" \
    DD_UWSGI_PORT="3031" \
    GENERATE_TLS_CERTIFICATE="false" \
    USE_TLS="false" \
    NGINX_METRICS_ENABLED="false" \
    METRICS_HTTP_AUTH_USER="" \
    METRICS_HTTP_AUTH_PASSWORD=""
ARG uid=1001
ARG appuser=owasp-ui
COPY --from=stage2 /app/static/ /usr/share/nginx/html/static/
COPY wsgi_params nginx/nginx.conf nginx/nginx_TLS.conf /etc/nginx/
COPY docker/entrypoint-nginx.sh /

USER ${uid}
EXPOSE 8080
ENTRYPOINT ["/entrypoint-nginx.sh"]

# Run the Nginx server

CMD ["/bin/bash", "-c", "envsubst '\$PORT \$APP_FRONTEND_URL \$APP_FRONTEND_PORT \$APP_BACKEND_URL \$APP_BACKEND_PORT' < /etc/nginx/sites-enabled/qaraisite.conf > /etc/nginx/sites-enabled/qaraisite.conf" && nginx -g 'daemon off;']
