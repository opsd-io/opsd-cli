#!/bin/sh
set -eu

ruby -Ilib:test -e 'Dir["test/*_test.rb"].sort.each { |f| load f }'
