#!/bin/bash

flutter test --coverage && \
	flutter pub run test_cov_console -c --output=coverage/test_coverage.csv

