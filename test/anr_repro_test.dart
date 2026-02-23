import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';

void main() {
  test('CustomATagMd regex performance test', () {
    final atag = CustomATagMd();
    final regex = atag.exp;

    // The text provided by the user that causes ANR
    final largeText = r'''
# Economics

**Type:** Note
**Tags:** shared, web, extracted, markdown, readability
**Created:** 02/08/2026

**Economics** ()[[1]](#cite_note-OED-1)[[2]](#cite_note-2) is a [social science](https://en.wikipedia.org/wiki/Social_science "Social science") that studies the [production](https://en.wikipedia.org/wiki/Production_(economics) "Production (economics)"), [distribution](https://en.wikipedia.org/wiki/Distribution_(economics) "Distribution (economics)"), and [consumption](https://en.wikipedia.org/wiki/Consumption_(economics) "Consumption (economics)") of [goods and services](https://en.wikipedia.org/wiki/Goods_and_services "Goods and services").[[3]](#cite_note-3)[[4]](#cite_note-4)

[![](https://upload.wikimedia.org/wikipedia/commons/c/cf/Economics_circular_flow_cartoon.jpg)](https://en.wikipedia.org/wiki/File:Economics_circular_flow_cartoon.jpg)

Three-sector [circular flow of income](https://en.wikipedia.org/wiki/Circular_flow_of_income "Circular flow of income") diagram

Economics focuses on the behaviour and interactions of [economic agents](https://en.wikipedia.org/wiki/Agent_(economics) "Agent (economics)") and how [economies](https://en.wikipedia.org/wiki/Economy "Economy") work. [Microeconomics](https://en.wikipedia.org/wiki/Microeconomics "Microeconomics") analyses what is viewed as basic elements within [economies](https://en.wikipedia.org/wiki/Economy "Economy"), including individual agents and [markets](https://en.wikipedia.org/wiki/Market_(economics) "Market (economics)"), their interactions, and the outcomes of interactions. Individual agents may include, for example, households, firms, buyers, and sellers. [Macroeconomics](https://en.wikipedia.org/wiki/Macroeconomics "Macroeconomics") analyses economies as systems where production, distribution, consumption, [savings](https://en.wikipedia.org/wiki/Savings "Savings"), and [investment expenditure](https://en.wikipedia.org/wiki/Expenditure "Expenditure") interact; and the [factors of production](https://en.wikipedia.org/wiki/Factors_of_production "Factors of production") affecting them, such as: [labour](https://en.wikipedia.org/wiki/Labour_(human_activity) "Labour (human activity)"), [capital](https://en.wikipedia.org/wiki/Capital_(economics) "Capital (economics)"), [land](https://en.wikipedia.org/wiki/Land_(economics) "Land (economics)"), and [enterprise](https://en.wikipedia.org/wiki/Entrepreneurship "Entrepreneurship"), [inflation](https://en.wikipedia.org/wiki/Inflation "Inflation"), [economic growth](https://en.wikipedia.org/wiki/Economic_growth "Economic growth"), and [public policies](https://en.wikipedia.org/wiki/Public_policies "Public policies") that impact [these elements](https://en.wikipedia.org/wiki/Glossary_of_economics "Glossary of economics"). It also seeks to [analyse and describe](https://en.wikipedia.org/wiki/International_economics "International economics") the [global economy](https://en.wikipedia.org/wiki/World_economy "World economy").

Other broad distinctions within economics include those between [positive economics](https://en.wikipedia.org/wiki/Positive_economics "Positive economics"), describing "what is", and [normative economics](https://en.wikipedia.org/wiki/Normative_economics "Normative economics"), advocating "what ought to be";[[5]](#cite_note-5) between economic theory and [applied economics](https://en.wikipedia.org/wiki/Applied_economics "Applied economics"); between [rational](https://en.wikipedia.org/wiki/Rational_choice_theory "Rational choice theory") and [behavioural economics](https://en.wikipedia.org/wiki/Behavioural_economics "Behavioural economics"); and between [mainstream economics](https://en.wikipedia.org/wiki/Mainstream_economics "Mainstream economics") and [heterodox economics](https://en.wikipedia.org/wiki/Heterodox_economics "Heterodox economics").[[6]](#cite_note-6)

Economic analysis can be applied throughout society, including [business](https://en.wikipedia.org/wiki/Business_economics "Business economics"),[[7]](#cite_note-7) [finance](https://en.wikipedia.org/wiki/Financial_economics "Financial economics"), [cybersecurity](https://en.wikipedia.org/wiki/Economics_of_security "Economics of security"),[[8]](#cite_note-8) [health care](https://en.wikipedia.org/wiki/Health_economics "Health economics"),[[9]](#cite_note-9) [engineering](https://en.wikipedia.org/wiki/Engineering_economics "Engineering economics")[[10]](#cite_note-Dharmaraj2010-10) and [government](https://en.wikipedia.org/wiki/Economic_policy "Economic policy").[[11]](#cite_note-11) It is also applied to such diverse subjects as [crime](https://en.wikipedia.org/wiki/Crime "Crime"),[[12]](#cite_note-12) [education](https://en.wikipedia.org/wiki/Education_economics "Education economics"),[[13]](#cite_note-13) the [family](https://en.wikipedia.org/wiki/Family_economics "Family economics"),[[14]](#cite_note-14) [feminism](https://en.wikipedia.org/wiki/Feminist_economics "Feminist economics"),[[15]](#cite_note-15) [law](https://en.wikipedia.org/wiki/Law_and_economics "Law and economics"),[[16]](#cite_note-16) [philosophy](https://en.wikipedia.org/wiki/Philosophy_and_economics "Philosophy and economics"),[[17]](#cite_note-17) [politics](https://en.wikipedia.org/wiki/Public_choice "Public choice"), [religion](https://en.wikipedia.org/wiki/Economics_of_religion "Economics of religion"),[[18]](#cite_note-18) [social institutions](https://en.wikipedia.org/wiki/Institutional_economics "Institutional economics"), [war](https://en.wikipedia.org/wiki/Economics_of_war "Economics of war"),[[19]](#cite_note-19) [science](https://en.wikipedia.org/wiki/Economics_of_science "Economics of science"),[[20]](#cite_note-20) and [the environment](https://en.wikipedia.org/wiki/Green_economics "Green economics").[[21]](#cite_note-21)
''';

    final stopwatch = Stopwatch()..start();
    final matches = regex.allMatches(largeText).toList();
    stopwatch.stop();

    print(
      'Found ${matches.length} matches in ${stopwatch.elapsedMilliseconds}ms',
    );

    // If it takes more than 100ms, it's likely problematic for the UI thread
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(200),
      reason: "Regex matching took too long",
    );
  });
}
