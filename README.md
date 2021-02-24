# Calibre On Docker

- [Calibre On Docker](#calibre-on-docker)
  - [Why Am I Doing This?](#why-am-i-doing-this)
  - [Why This Solution?](#why-this-solution)
  - [Setup](#setup)
    - [Directory Structure](#directory-structure)
    - [Configuration Variables](#configuration-variables)
    - [Docker Build](#docker-build)
    - [docker-compose.yml](#docker-composeyml)
    - [Run Calibre](#run-calibre)
    - [Notes](#notes)
  - [Further Reading](#further-reading)


## Why Am I Doing This?

Over the years I have managed to accumulate hundreds of eBooks stored across a number of locations. It was not easy to find anything specific I was looking for. I resisted using the Calibre desktop app because I don't want to be tied to a specific computer. Between personal and work systems I use several on a frequent basis, and did not want to be tied to a specific one.

## Why This Solution?

First, I wanted a server solution so that I could access my library anywhere on my home network. I looked at the server component of Calibre but found it to be ugly and awkward to use. @kovidgoyal has done a great job on the project, but he has focused more on the desktop app than calibre-server from a usability perspective. I found Calibre Web and really like the interface and usability.

Second, I wanted automated ingestion of new books. My library is currently >250 books, many with multiple formats (mobi, epub, pdf). I would rather spend my time with the interesting work of creating an automated solution instead of the toil of manually adding each book and format. I found that Calibre's ingestion was more accurate for adding new formats of existing books than Calibre Web, but there were still some shortcomings, mostly due to the haphazard nature of the filenames and tagging for my files. I wrote a script to remedy as much of this as I could.

Finally, I wanted to run in a container. I wanted the portability of moving this from system to system as my home network changes. I started this project running on a Linux desktop computer circa 2011 that I use as a sandbox. I am in process of moving this to a Raspberry Pi Kubernetes cluster. The data lives on an NFS share elsewhere on the network making it a relatively easy transition (once I finish setting up k8s).

## Setup

Setting up `docker` and `docker-compose` are beyond the scope of this. See [Further Reading](#further-reading) for more info on that.

### Directory Structure

`docker-compose.yml` is written using bind mounts with relative addresses. Due to this the directory structure is very specific and must follow the director tree specified below:
```
$ tree -d -L 1 ./
./              # the base directory for your calibre/docker setup
├── addbooks    # the consumption directory to be mounted in both containers
├── books       # the data directory to be mounted in the calibredb container
├── data        # the data directory to be mounted in the calibre-web container
└── docker      # the directory containing docker-compose.yml and support files
```

### Configuration Variables

All configuration variables are fully documented in `docker-compose.env.example`. 

### Docker Build

If desired, you can build the docker image locally after cloning this git repo:
```bash
$ docker build --rm -t drbayer/calibredb:latest -f Dockerfile.calibredb-alpine .
```

### docker-compose.yml

There are a couple of edits that you must make before running `docker-compose up`. I am running [Traefik](https://hub.docker.com/_/traefik) load balancer/reverse proxy on my docker host to make using services a more pleasant experience. Setup/config of Traefik itself is beyond the scope of this project, but I have left the required configs in this docker-compose file to show how you can attach services to Traefik.

If you choose not to run Traefik:
* Remove or update `networks.default.external.name: traefik` (lines 3-6)

If you run Traefik:
* Remove or update `networks.default.external.name: traefik` (lines 3-6)
* Update the `Host` filter label for `calibre-web` (line 18) to reflect your domain name

### Run Calibre

Once you've set up everything above, the following command will start up the containers:
```bash
# These commands must be run from the directory containing docker-compose.yml
$ docker-compose up -d

# View logs
$ docker-compose logs -f
```

### Notes

* `add_books.sh` uses `inotifywait` to monitor the consumption directory for new content. This DOES NOT WORK with certain network mounts - most notably SMB shares. It works as advertised with either local disks or NFS mounts on the host machine. Presumably it would also work with iSCSI targets, but that is as yet untested.
* If an existing database is not found in CALIBREDB_LIBRARY, `add_books.sh` will initialize a new, empty database.


## Further Reading

[Calibre](https://calibre-ebook.com): A free eBook library management application. It is intended to run as a desktop application, but it also includes a server component for over-the-air eBook transfers as well as a command line interface for administration.

[Calibre Web](https://github.com/janeczku/calibre-web): A web app frontend that provides a nicer interface for browsing, reading and downloading eBooks from a *pre-existing Calibre database*. 

[Docker](https://docs.docker.com/get-docker/): Container platform

[Docker Compose](https://docs.docker.com/compose/): Basic orchestration of Docker containers. Allows running multiple containers as a service.

[Traefik](https://hub.docker.com/_/traefik): A reverse proxy/load balancer for microservices.