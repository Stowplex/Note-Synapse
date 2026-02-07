#!/bin/bash

rm -rf coverage
mkdir coverage

flutter test --coverage --reporter expanded 2>1 > coverage/test_output && \
	flutter pub run test_cov_console -c --output=coverage/test_coverage.csv

