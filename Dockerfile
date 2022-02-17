FROM node:15.12.0-alpine3.10 as dev

RUN mkdir /app
WORKDIR /app

COPY ./package.json ./yarn.lock ./
RUN yarn

CMD ["yarn", "next", "dev"]

FROM dev AS build

RUN next build