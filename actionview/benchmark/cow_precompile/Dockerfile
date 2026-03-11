FROM ruby:4.0

COPY . /rails
WORKDIR /rails/actionview/benchmark/cow_precompile

RUN bundle install --jobs 4 --retry 3

CMD ["ruby", "benchmark.rb"]
