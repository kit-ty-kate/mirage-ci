FROM ocaml/opam2:alpine
RUN sudo apk add --update docker
RUN cd /home/opam/opam-repository && git pull origin master && opam update -uy
RUN opam depext -uivy irmin-unix ezjsonm bos ptime fmt datakit-ci conf-libev 
ADD --chown=1000 mirage-ci.opam /home/opam/src/
RUN opam install --deps-only /home/opam/src/
ADD --chown=1000 . /home/opam/src
RUN opam pin add -n mirage-ci /home/opam/src
RUN opam install -vy mirage-ci
ENV CONDUIT_TLS=native
ENV OCAMLRUNPARAM=b
USER root
CMD []
