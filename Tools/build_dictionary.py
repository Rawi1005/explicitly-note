#!/usr/bin/env python3
"""Builds SmartNotes/Resources/dictionary.sqlite, the bundled offline
dictionary database consumed by SQLiteOfflineDictionaryService.swift.

Standard library only (sqlite3, json, argparse) — no third-party packages,
matching the "no dependencies" rule of the SmartNotes iOS project.

Schema (see also SQLiteOfflineDictionaryService.swift, which reads this
exact shape):

    CREATE TABLE entries (
        id INTEGER PRIMARY KEY,
        word TEXT NOT NULL,            -- normalized: lowercase, trimmed
        part_of_speech TEXT,           -- noun/verb/adjective/adverb/...
        definition TEXT NOT NULL,
        example TEXT,                  -- nullable
        synonyms TEXT,                 -- pipe-delimited "a|b|c", nullable
        antonyms TEXT,                 -- pipe-delimited, nullable
        sense_index INTEGER NOT NULL   -- ordering within a word
    );
    CREATE INDEX idx_entries_word ON entries(word);

Two modes:

  --seed
      Writes the curated starter word list embedded in this file
      (SEED_DATA below, ~130 common English words). This is the mode
      actually used to produce the dictionary.sqlite committed to the
      repo — it needs no external input and runs anywhere Python 3 runs.

  --wordnet PATH
      Ingests a full dictionary from a WordNet-derived JSON file at PATH,
      for a maintainer who wants to regenerate a much larger database on
      their own machine later. The expected JSON shape is a flat list of
      per-sense objects, one per row of the `entries` table, e.g.:

          [
            {
              "word": "run",
              "part_of_speech": "verb",
              "definition": "To move at a pace faster than a walk...",
              "example": "She runs five miles every morning.",
              "synonyms": ["sprint", "jog"],
              "antonyms": ["walk"]
            },
            ...
          ]

      Rules for that file:
        * "word" and "definition" are required; everything else may be
          null/omitted.
        * "word" must already be normalized (lowercase, trimmed) the same
          way WordNormalizer.swift normalizes lookups, or the offline
          service will silently fail to match it.
        * Entries for the same word must appear in the JSON in the order
          they should be presented in the app — sense_index is assigned
          from that order, grouped per word as encountered.

Usage:
    python3 Tools/build_dictionary.py --seed
    python3 Tools/build_dictionary.py --wordnet /path/to/wordnet.json
    python3 Tools/build_dictionary.py --seed --output /tmp/test.sqlite
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Iterable

DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "SmartNotes" / "Resources" / "dictionary.sqlite"

# ---------------------------------------------------------------------------
# Seed dataset
#
# WORDS maps a normalized word -> an ordered list of senses. Each sense is a
# tuple: (part_of_speech, definition, example_or_None, synonyms_or_None,
# antonyms_or_None). List order becomes sense_index (0-based) so multi-sense
# words like "run" or "bank" present their senses in a sensible order.
#
# A mix of single-sense technical/science words and multi-sense everyday
# words is intentional: it lets the app demonstrate both a clean single
# definition and the richer grouped-by-part-of-speech UI, and it lets the
# found/not-found escalation to AI be tested against words guaranteed to be
# absent (e.g. "photosynthesis" is present, "photosynthesize" is not).
# ---------------------------------------------------------------------------

WORDS: dict[str, list[tuple[str, str, str | None, list[str] | None, list[str] | None]]] = {
    # --- Single-sense science / technical vocabulary -----------------------
    "photosynthesis": [
        ("noun", "The process by which green plants and some other organisms use sunlight to synthesize nutrients from carbon dioxide and water, releasing oxygen as a byproduct.", "Photosynthesis takes place mainly in the leaves of a plant.", None, None),
    ],
    "entropy": [
        ("noun", "A measure of the disorder or randomness in a system, which tends to increase over time in an isolated system.", "The universe's entropy increases as energy disperses.", ["disorder"], ["order"]),
    ],
    "chlorophyll": [
        ("noun", "The green pigment found in plants and algae that absorbs light to power photosynthesis.", "Chlorophyll gives leaves their green color.", None, None),
    ],
    "gravity": [
        ("noun", "The force that attracts objects with mass toward one another, especially the force that pulls objects toward the center of the Earth.", "An apple falls to the ground because of gravity.", ["gravitation"], None),
    ],
    "oxygen": [
        ("noun", "A colorless, odorless reactive gas that makes up about one-fifth of Earth's atmosphere and is essential for most life.", "Humans need oxygen to breathe.", None, None),
    ],
    "hydrogen": [
        ("noun", "The lightest and most abundant chemical element, a colorless flammable gas that combines with oxygen to form water.", "Hydrogen is the simplest element on the periodic table.", None, None),
    ],
    "nitrogen": [
        ("noun", "A colorless, mostly unreactive gas that makes up about four-fifths of Earth's atmosphere and is a key component of proteins and DNA.", "Nitrogen is essential for plant growth.", None, None),
    ],
    "ecosystem": [
        ("noun", "A community of living organisms together with the nonliving components of their environment, interacting as a system.", "A coral reef is a rich and fragile ecosystem.", None, None),
    ],
    "biodiversity": [
        ("noun", "The variety of plant and animal life in a particular habitat or in the world as a whole.", "Rainforests hold an extraordinary amount of biodiversity.", ["biological diversity"], None),
    ],
    "metabolism": [
        ("noun", "The chemical processes within a living organism that convert food into energy and sustain life.", "Exercise can help speed up your metabolism.", None, None),
    ],
    "osmosis": [
        ("noun", "The gradual movement of a solvent through a semipermeable membrane from a less concentrated solution to a more concentrated one.", "Water enters plant roots by osmosis.", None, None),
    ],
    "evolution": [
        ("noun", "The gradual process by which species of organisms change over successive generations through natural selection.", "Darwin's theory of evolution reshaped biology.", ["development"], ["stasis"]),
    ],
    "chromosome": [
        ("noun", "A thread-like structure of nucleic acid and protein found in the nucleus of a cell, carrying genetic information in the form of genes.", "Humans typically have 46 chromosomes in each cell.", None, None),
    ],
    "enzyme": [
        ("noun", "A protein that acts as a catalyst to speed up a specific chemical reaction in a living organism.", "Enzymes in saliva begin breaking down starch.", None, None),
    ],
    "bacterium": [
        ("noun", "A microscopic single-celled organism that can exist as an independent living unit, some of which cause disease.", "Not every bacterium is harmful to humans.", ["microbe"], None),
    ],
    "antibiotic": [
        ("noun", "A medicine that destroys or slows the growth of bacteria, used to treat bacterial infections.", "The doctor prescribed an antibiotic for the infection.", None, None),
    ],
    "telescope": [
        ("noun", "An optical instrument that uses lenses or mirrors to make distant objects, especially celestial ones, appear larger and closer.", "She used a telescope to observe Saturn's rings.", None, None),
    ],
    "asteroid": [
        ("noun", "A small rocky body, smaller than a planet, that orbits the sun, most commonly found in the asteroid belt between Mars and Jupiter.", "An asteroid struck the Yucatan Peninsula millions of years ago.", None, None),
    ],
    "galaxy": [
        ("noun", "A huge system of stars, gas, dust, and dark matter held together by gravity, such as the Milky Way.", "Our galaxy contains hundreds of billions of stars.", None, None),
    ],
    "photon": [
        ("noun", "A particle representing a quantum of light or other electromagnetic radiation, carrying energy but no mass.", "Photons travel at the speed of light.", None, None),
    ],

    # --- Common, often multi-sense, everyday words --------------------------
    "run": [
        ("verb", "To move at a pace faster than a walk, using quick steps so that both feet leave the ground during each stride.", "She runs five miles every morning.", ["sprint", "jog"], ["walk"]),
        ("verb", "To manage or operate a business, organization, or system.", "He runs a small bakery downtown.", ["manage", "operate"], None),
        ("noun", "An act or spell of running, or a journey made along a fixed route.", "We went for a run in the park.", None, None),
    ],
    "bank": [
        ("noun", "A financial institution that accepts deposits, makes loans, and provides other financial services.", "She deposited her paycheck at the bank.", None, None),
        ("noun", "The land alongside or sloping down to a river, lake, or other body of water.", "They had a picnic on the river bank.", None, None),
        ("verb", "To deposit money into a bank account.", "He banks his salary every month.", None, None),
    ],
    "light": [
        ("noun", "The natural agent that stimulates sight and makes things visible; electromagnetic radiation within the visible spectrum.", "Sunlight streamed through the window.", ["illumination"], ["darkness"]),
        ("adjective", "Having little weight; not heavy.", "The suitcase was surprisingly light.", ["lightweight"], ["heavy"]),
        ("verb", "To ignite something or cause it to start burning.", "She lit a candle on the table.", None, None),
    ],
    "set": [
        ("verb", "To put something in a specified place or position.", "He set the vase on the shelf.", ["place", "put"], None),
        ("verb", "Of the sun or moon, to move down toward and below the horizon.", "The sun sets in the west.", None, ["rise"]),
        ("noun", "A group of things that belong together or are used together.", "She bought a new set of dishes.", ["collection"], None),
    ],
    "book": [
        ("noun", "A written or printed work consisting of pages bound together, usually protected by a cover.", "She read a book on the train.", None, None),
        ("verb", "To reserve accommodations, tickets, or a place in advance.", "We booked a table for dinner at eight.", ["reserve"], None),
    ],
    "watch": [
        ("verb", "To look at or observe attentively over a period of time.", "They watched the sunset from the balcony.", ["observe"], None),
        ("noun", "A small timepiece worn typically on a strap around the wrist.", "He checked the time on his watch.", None, None),
        ("verb", "To guard or keep an eye on something for protection.", "Please watch my bag while I'm gone.", ["guard", "mind"], None),
    ],
    "table": [
        ("noun", "A piece of furniture with a flat top and one or more legs, used for eating, working, or placing things on.", "They gathered around the kitchen table.", None, None),
        ("noun", "An arrangement of data in rows and columns.", "The report included a table of quarterly sales.", None, None),
        ("verb", "To postpone consideration of a proposal or motion.", "The committee decided to table the discussion until next week.", None, None),
    ],
    "spring": [
        ("noun", "The season after winter and before summer, when plants begin to grow again.", "Flowers bloom in spring.", None, None),
        ("noun", "A coiled piece of metal that returns to its original shape after being compressed or stretched.", "The mattress is filled with springs.", None, None),
        ("verb", "To jump or move suddenly and quickly upward or forward.", "The cat sprang onto the counter.", ["leap", "jump"], None),
    ],
    "bright": [
        ("adjective", "Giving out or reflecting a lot of light; shining.", "The bright sun made her squint.", ["radiant", "luminous"], ["dim"]),
        ("adjective", "Intelligent and quick-witted.", "He's a bright student who learns fast.", ["smart", "clever"], ["dull"]),
    ],
    "fast": [
        ("adjective", "Moving or capable of moving at high speed.", "She is a fast runner.", ["quick", "rapid"], ["slow"]),
        ("verb", "To abstain from all or some kinds of food or drink, especially for religious or health reasons.", "Many people fast during Ramadan.", None, None),
    ],
    "hard": [
        ("adjective", "Solid, firm, and resistant to pressure; not easily broken or bent.", "The rock felt hard beneath her hand.", ["firm", "solid"], ["soft"]),
        ("adjective", "Difficult to do, understand, or accomplish.", "The exam was really hard.", ["difficult"], ["easy"]),
    ],
    "right": [
        ("adjective", "Correct according to fact, reason, or truth.", "You were right about the weather.", ["correct"], ["wrong"]),
        ("noun", "A moral or legal entitlement to have or do something.", "Everyone has the right to free speech.", None, None),
        ("adjective", "On or toward the side of the body that is to the east when a person faces north.", "Turn right at the next corner.", None, ["left"]),
    ],
    "well": [
        ("adverb", "In a good, satisfactory, or thorough manner.", "She plays the piano well.", None, ["badly"]),
        ("noun", "A deep hole in the ground from which water, oil, or gas is drawn.", "The village gets its water from a well.", None, None),
        ("adjective", "In good health.", "He hasn't been well lately.", ["healthy"], ["sick"]),
    ],
    "drink": [
        ("verb", "To take liquid into the mouth and swallow it.", "She drank a glass of water.", None, None),
        ("noun", "A liquid that is swallowed to quench thirst, for nourishment, or for pleasure.", "Would you like a cold drink?", ["beverage"], None),
        ("verb", "To consume alcoholic beverages, especially habitually or excessively.", "He doesn't drink anymore.", None, None),
    ],
    "play": [
        ("verb", "To engage in an activity for enjoyment rather than a serious or practical purpose.", "The children played in the yard.", ["frolic"], None),
        ("verb", "To take part in a sport or game.", "They play soccer every weekend.", None, None),
        ("noun", "A dramatic work intended for performance on a stage.", "We saw a play at the local theater.", None, None),
    ],
    "match": [
        ("noun", "A short, thin stick of wood or cardboard tipped with a flammable substance, used to light a fire.", "He struck a match to light the candle.", None, None),
        ("noun", "A contest or game between two or more people or teams.", "The tennis match lasted three hours.", None, None),
        ("verb", "To correspond to or be similar to something else.", "Her scarf matches her coat.", ["correspond", "suit"], None),
    ],
    "note": [
        ("noun", "A brief written record of facts, topics, or thoughts, used as an aid to memory.", "She jotted down a note during the meeting.", None, None),
        ("noun", "A single tone of definite pitch in music, or the symbol representing it.", "He played the wrong note on the piano.", None, None),
        ("verb", "To notice or pay close attention to something.", "Please note that the office is closed on Sundays.", ["observe"], None),
    ],
    "point": [
        ("noun", "The sharp end of something, such as a needle or pencil.", "The point of the pencil broke.", None, None),
        ("noun", "A particular spot, position, or moment.", "At this point in the story, the hero appears.", None, None),
        ("verb", "To extend a finger or object toward something to indicate its position.", "She pointed at the map.", None, None),
    ],
    "fair": [
        ("adjective", "Treating people equally, without favoritism or discrimination.", "The referee made a fair decision.", ["just", "impartial"], ["unfair"]),
        ("noun", "An event with entertainment, competitions, and stalls, often held outdoors.", "They went to the county fair.", None, None),
        ("adjective", "Of hair or skin, light in color.", "She has fair skin and blonde hair.", None, None),
    ],
    "bear": [
        ("noun", "A large, heavy mammal with thick fur, found in forests and mountains.", "A brown bear wandered near the campsite.", None, None),
        ("verb", "To carry or support the weight of something.", "The bridge can bear heavy loads.", ["support", "carry"], None),
        ("verb", "To endure or tolerate something difficult or painful.", "She could hardly bear the pain.", ["endure", "tolerate"], None),
    ],
    "bat": [
        ("noun", "A nocturnal flying mammal with membranous wings.", "Bats use echolocation to navigate in the dark.", None, None),
        ("noun", "A shaped piece of wood used to hit the ball in games such as baseball or cricket.", "He swung the bat and hit a home run.", None, None),
        ("verb", "To take a turn hitting the ball in a game such as baseball or cricket.", "Our team bats first.", None, None),
    ],
    "fly": [
        ("verb", "To move through the air using wings or engine power.", "Birds fly south for the winter.", None, None),
        ("noun", "A small flying insect with two wings.", "A fly landed on the picnic table.", None, None),
        ("verb", "To move or pass quickly.", "Time really flew by during the concert.", ["speed", "dash"], None),
    ],
    "ring": [
        ("noun", "A small circular band, typically of precious metal, worn on a finger.", "He proposed with a diamond ring.", None, None),
        ("verb", "To make a clear resonant sound, as a bell does.", "The phone rang three times before she answered.", ["chime", "toll"], None),
        ("noun", "A circular area or arena for boxing, wrestling, or performances.", "The boxers stepped into the ring.", None, None),
    ],
    "rock": [
        ("noun", "The solid mineral material forming part of the earth's surface.", "The cliff was made of solid rock.", None, None),
        ("verb", "To move gently back and forth or from side to side.", "She rocked the baby to sleep.", ["sway"], None),
        ("noun", "A genre of popular music characterized by a strong beat and amplified instruments.", "He grew up listening to classic rock.", None, None),
    ],
    "fire": [
        ("noun", "Combustion producing light, heat, and flame.", "They gathered around the campfire.", ["flame", "blaze"], None),
        ("verb", "To dismiss someone from a job.", "The manager fired two employees.", ["dismiss"], ["hire"]),
        ("verb", "To discharge a weapon or shoot a projectile.", "The soldiers fired at the target.", None, None),
    ],
    "cold": [
        ("adjective", "Having a low temperature; not warm.", "The water in the lake was freezing cold.", ["chilly", "frigid"], ["hot"]),
        ("noun", "A common mild viral infection causing sneezing, sore throat, and a runny nose.", "She caught a cold last week.", None, None),
        ("adjective", "Unfriendly or lacking affection.", "His cold response surprised her.", ["unfriendly"], ["warm"]),
    ],
    "cool": [
        ("adjective", "Of or at a fairly low temperature; not warm or hot.", "A cool breeze drifted through the window.", None, ["warm"]),
        ("adjective", "Informal: fashionable, impressive, or admirable.", "That's a really cool jacket.", ["stylish"], None),
        ("verb", "To make or become less warm.", "Let the soup cool before serving.", None, None),
    ],
    "warm": [
        ("adjective", "Having a moderately high temperature; pleasantly hot.", "The blanket kept her warm all night.", None, ["cold"]),
        ("adjective", "Friendly, kind, and affectionate in manner.", "She gave him a warm welcome.", ["friendly"], ["cold"]),
        ("verb", "To make or become warmer.", "He warmed his hands by the fire.", None, None),
    ],
    "hot": [
        ("adjective", "Having a high temperature.", "The soup was too hot to eat right away.", None, ["cold"]),
        ("adjective", "Of food, containing pungent spices that produce a burning sensation.", "He ordered the extra hot salsa.", ["spicy"], None),
        ("adjective", "Currently very popular or in high demand.", "That new phone is the hot item this season.", ["popular"], None),
    ],
    "break": [
        ("verb", "To separate into pieces as a result of a blow, strain, or other force.", "The glass broke when it hit the floor.", ["shatter", "crack"], None),
        ("noun", "A short period of rest from work or activity.", "Let's take a coffee break.", ["rest", "pause"], None),
        ("verb", "To fail to observe a law, rule, or promise.", "He broke his promise to call.", ["violate"], None),
    ],
    "cut": [
        ("verb", "To divide or separate something using a sharp tool.", "She cut the bread into thick slices.", ["slice"], None),
        ("noun", "A wound or opening made by a sharp instrument.", "He got a small cut on his finger.", None, None),
        ("verb", "To reduce the amount, extent, or duration of something.", "The company cut its prices.", ["reduce"], ["increase"]),
    ],
    "draw": [
        ("verb", "To produce a picture or diagram by making lines on a surface.", "She drew a sketch of the mountains.", ["sketch"], None),
        ("verb", "To pull something toward oneself or in a specified direction.", "He drew the curtains to block the sun.", ["pull"], None),
        ("noun", "A result in a game or contest in which neither side wins.", "The match ended in a draw.", ["tie"], None),
    ],
    "drop": [
        ("verb", "To fall or let something fall straight down.", "The plate slipped and dropped to the floor.", ["fall"], None),
        ("noun", "A small round quantity of liquid that falls or hangs.", "A drop of rain landed on her nose.", None, None),
        ("verb", "To stop doing, having, or taking part in something.", "She dropped the class after the first week.", ["abandon", "quit"], None),
    ],
    "fall": [
        ("verb", "To move downward, typically rapidly and freely, without control.", "Leaves fall from the trees in autumn.", ["drop"], ["rise"]),
        ("noun", "The season after summer and before winter; autumn.", "The leaves change color every fall.", None, None),
        ("noun", "An amount by which something, such as a price, decreases.", "There was a sharp fall in stock prices.", None, ["rise"]),
    ],
    "hand": [
        ("noun", "The end part of a person's arm, used for grasping and holding.", "She raised her hand to ask a question.", None, None),
        ("verb", "To give or pass something to someone using the hand.", "Could you hand me that book?", ["pass", "give"], None),
        ("noun", "A pointer on a clock or watch that indicates the time.", "The minute hand moved slowly toward twelve.", None, None),
    ],
    "head": [
        ("noun", "The upper part of the human body, containing the brain, eyes, and mouth.", "He bumped his head on the doorframe.", None, None),
        ("noun", "The person in charge of a group or organization.", "She is the head of the marketing department.", ["chief", "leader"], None),
        ("verb", "To move in a specified direction.", "They headed north toward the mountains.", None, None),
    ],
    "jump": [
        ("verb", "To push oneself off the ground using the legs, moving suddenly into the air.", "The dog jumped over the fence.", ["leap", "hop"], None),
        ("noun", "A sudden act of jumping.", "She landed the jump perfectly.", None, None),
        ("verb", "To increase suddenly and sharply.", "Prices jumped after the shortage.", ["surge"], None),
    ],
    "kick": [
        ("verb", "To strike something with the foot.", "He kicked the ball into the net.", None, None),
        ("noun", "An act of striking with the foot.", "The winning goal came from a powerful kick.", None, None),
        ("noun", "Informal: a thrill or feeling of excitement.", "She gets a kick out of roller coasters.", ["thrill"], None),
    ],
    "land": [
        ("noun", "The solid part of the earth's surface, as opposed to sea or air.", "After weeks at sea, they finally spotted land.", None, ["sea"]),
        ("verb", "To come down to the ground or another surface after a flight or jump.", "The plane landed safely.", None, None),
        ("noun", "An area of ground owned or used for a particular purpose.", "They bought a plot of land to build a house.", None, None),
    ],
    "mark": [
        ("noun", "A small area on a surface that differs from the surrounding area, often caused by damage or staining.", "There's a mark on the wall from the picture frame.", ["stain", "spot"], None),
        ("verb", "To assign a grade or score to a piece of work.", "The teacher marked the essays over the weekend.", ["grade"], None),
        ("noun", "A written or printed symbol used to indicate something.", "Use a question mark at the end of the sentence.", None, None),
    ],
    "mind": [
        ("noun", "The element of a person that enables thought, feeling, and awareness.", "She has a sharp mind for numbers.", ["intellect"], None),
        ("verb", "To be bothered by or object to something.", "Would you mind opening the window?", None, None),
        ("verb", "To pay attention to and look after someone or something.", "Please mind the gap between the train and the platform.", ["watch", "heed"], None),
    ],
    "order": [
        ("noun", "The arrangement or sequence in which things are placed.", "Put the files in alphabetical order.", ["sequence", "arrangement"], None),
        ("verb", "To request that something be supplied or made.", "We ordered pizza for dinner.", None, None),
        ("noun", "A command given with authority.", "The general gave the order to retreat.", ["command", "directive"], None),
    ],
    "park": [
        ("noun", "A large public garden or area of land used for recreation.", "The kids played in the park after school.", None, None),
        ("verb", "To bring a vehicle to a stop and leave it temporarily in a particular place.", "She parked the car outside the store.", None, None),
    ],
    "pass": [
        ("verb", "To move onward or past something.", "The train passed through the tunnel.", None, None),
        ("verb", "To achieve a satisfactory grade on an exam or course.", "He passed his driving test on the first try.", None, ["fail"]),
        ("noun", "An official document or ticket permitting entry or travel.", "You'll need a pass to enter the stadium.", None, None),
    ],
    "pick": [
        ("verb", "To choose or select someone or something from a group.", "She picked the red apple from the basket.", ["choose", "select"], None),
        ("verb", "To remove a flower, fruit, or crop from where it grows.", "They picked strawberries all morning.", ["harvest"], None),
        ("noun", "A choice or selection.", "This restaurant is my top pick for dinner.", None, None),
    ],
    "place": [
        ("noun", "A particular position, point, or area in space.", "This is a good place for a picnic.", ["location", "spot"], None),
        ("verb", "To put something in a particular position.", "She placed the book on the shelf.", ["put", "set"], None),
        ("noun", "A person's rank or position in a competition or sequence.", "He finished in second place.", None, None),
    ],
    "plant": [
        ("noun", "A living organism that typically grows in soil, has leaves and roots, and makes its own food through photosynthesis.", "She watered the plant every morning.", None, None),
        ("verb", "To put a seed, bulb, or plant into the ground so it can grow.", "They planted tomatoes in the garden.", None, None),
        ("noun", "A factory or industrial building where an industrial process takes place.", "The car parts are made at the local plant.", None, None),
    ],
    "pool": [
        ("noun", "A small area of still water, or an artificial basin for swimming.", "They spent the afternoon swimming in the pool.", None, None),
        ("noun", "A shared supply of money, vehicles, or resources available for use by a group.", "The company keeps a pool of company cars.", ["fund", "reserve"], None),
        ("verb", "To combine resources or money for a common purpose.", "They pooled their money to buy a gift.", None, None),
    ],
    "post": [
        ("noun", "A long, sturdy piece of wood or metal set upright in the ground.", "The fence was attached to a wooden post.", None, None),
        ("noun", "A position of paid employment.", "She was appointed to the post of manager.", ["job", "position"], None),
        ("verb", "To display or publish something, especially online.", "He posted a photo on social media.", None, None),
    ],
    "present": [
        ("adjective", "Existing or occurring now, at this time.", "Please state your present address.", None, ["past"]),
        ("noun", "A gift given to someone.", "She gave him a birthday present.", ["gift"], None),
        ("verb", "To give, show, or offer something formally.", "The teacher presented the awards to the students.", None, None),
    ],
    "pull": [
        ("verb", "To exert force on something so as to move it toward oneself.", "He pulled the rope with all his strength.", None, ["push"]),
        ("noun", "An act of pulling something.", "Give the door a firm pull to open it.", None, None),
    ],
    "push": [
        ("verb", "To exert force on something to move it away from oneself.", "She pushed the cart down the aisle.", None, ["pull"]),
        ("noun", "A sustained effort to achieve or promote something.", "The company launched a big push to increase sales.", ["drive", "effort"], None),
    ],
    "race": [
        ("noun", "A competition to determine who is fastest over a set course or distance.", "She won the 100-meter race.", None, None),
        ("noun", "A group of people sharing distinct physical or social characteristics, historically used to classify humans.", "The event celebrated people of every race and background.", None, None),
        ("verb", "To compete to see who is fastest.", "The kids raced each other to the fence.", None, None),
    ],
    "rest": [
        ("noun", "A period of relaxation or inactivity after exertion.", "After the hike, they took a well-deserved rest.", ["relaxation"], None),
        ("verb", "To cease work or movement in order to relax or recover.", "The doctor told him to rest for a few days.", None, None),
        ("noun", "The remaining part of something.", "She ate half the cake and saved the rest.", ["remainder"], None),
    ],
    "rise": [
        ("verb", "To move upward, or to increase in amount or level.", "Smoke rose from the chimney.", None, ["fall"]),
        ("noun", "An increase in amount, number, or value.", "There was a sharp rise in temperature.", None, ["fall", "decline"]),
        ("verb", "To get up from a lying, sitting, or kneeling position.", "He rose from his chair to greet her.", None, None),
    ],
    "roll": [
        ("verb", "To move by turning over and over on an axis.", "The ball rolled down the hill.", None, None),
        ("noun", "A small rounded piece of bread.", "She buttered a warm dinner roll.", None, None),
        ("noun", "An official list of names, such as of students or members.", "The teacher called the roll each morning.", None, None),
    ],
    "root": [
        ("noun", "The part of a plant that grows underground, absorbing water and nutrients.", "The tree's roots spread far beneath the soil.", None, None),
        ("noun", "The basic cause, source, or origin of something.", "They tried to get to the root of the problem.", ["source", "origin"], None),
        ("verb", "To support or cheer for someone, especially in a competition.", "We're all rooting for the home team.", None, None),
    ],
    "rule": [
        ("noun", "A statement that guides behavior or indicates what is allowed.", "It's against the rules to run in the hallway.", ["regulation", "law"], None),
        ("verb", "To exercise governing power or authority over a country or people.", "The queen ruled for over sixty years.", ["govern", "reign"], None),
    ],
    "sail": [
        ("noun", "A piece of fabric used to catch the wind and propel a boat.", "The wind filled the ship's sails.", None, None),
        ("verb", "To travel on water in a boat or ship, especially using sails.", "They sailed across the Atlantic Ocean.", None, None),
    ],
    "save": [
        ("verb", "To keep someone or something safe from harm or danger.", "The lifeguard saved the swimmer from drowning.", ["rescue"], None),
        ("verb", "To set aside money for future use.", "She saves a portion of her paycheck every month.", None, None),
        ("verb", "To store data on a computer for future use.", "Remember to save your document before closing it.", None, None),
    ],
    "scale": [
        ("noun", "A device used for weighing.", "He stepped on the scale to check his weight.", None, None),
        ("noun", "A graduated range of values that measures or compares something.", "Rate your pain on a scale of one to ten.", None, None),
        ("verb", "To climb up or over something steep or high.", "The climbers scaled the cliff face.", ["climb"], None),
    ],
    "school": [
        ("noun", "An institution for educating children or adults.", "The children walked to school together.", None, None),
        ("noun", "A large group of fish or sea mammals swimming together.", "A school of dolphins swam alongside the boat.", None, None),
        ("verb", "To educate or train someone in a particular subject.", "He was schooled in classical music from a young age.", None, None),
    ],
    "seal": [
        ("noun", "A marine mammal with flippers that lives partly on land and partly in the sea.", "A seal basked on the rocks near the shore.", None, None),
        ("noun", "A device or substance used to join two surfaces together and prevent leakage.", "Check that the seal on the jar isn't broken.", None, None),
        ("verb", "To close something securely so that it cannot be opened without breaking the fastening.", "She sealed the envelope before mailing it.", ["close", "shut"], None),
    ],
    "season": [
        ("noun", "One of the four divisions of the year, such as spring, summer, autumn, or winter.", "Autumn is her favorite season.", None, None),
        ("verb", "To add salt, herbs, or spices to food to enhance its flavor.", "Season the chicken with salt and pepper.", ["flavor"], None),
        ("noun", "A period of the year associated with a particular activity.", "Tourist season begins in June.", None, None),
    ],
    "seat": [
        ("noun", "A piece of furniture or place designed for sitting.", "Please take a seat while you wait.", None, None),
        ("verb", "To arrange for someone to sit somewhere.", "The host seated us near the window.", None, None),
        ("noun", "A position as a member of a legislative or other body.", "She won a seat in the city council election.", None, None),
    ],
    "second": [
        ("noun", "A unit of time equal to one sixtieth of a minute.", "The race was decided by a fraction of a second.", None, None),
        ("adjective", "Coming immediately after the first in order or importance.", "She finished in second place.", None, None),
        ("verb", "To formally support a motion or proposal made by another person.", "I second the motion to adjourn the meeting.", None, None),
    ],
    "sense": [
        ("noun", "Any of the faculties, such as sight or hearing, by which the body perceives the external world.", "Dogs have a keen sense of smell.", None, None),
        ("noun", "A reasonable or practical understanding of something.", "She has a good sense of direction.", ["judgment"], None),
        ("verb", "To become aware of something through instinct or without being told directly.", "He could sense that something was wrong.", ["perceive", "feel"], None),
    ],
    "shed": [
        ("noun", "A simple structure, typically made of wood or metal, used for storage or shelter.", "The tools are kept in the garden shed.", None, None),
        ("verb", "To lose or let fall hair, skin, leaves, or another outer covering naturally.", "Snakes shed their skin periodically.", None, None),
        ("verb", "To get rid of something unwanted, such as weight or a habit.", "He managed to shed ten pounds before summer.", ["lose"], None),
    ],
    "shift": [
        ("noun", "A designated period of time during which a group of workers is on duty.", "She works the night shift at the hospital.", None, None),
        ("verb", "To move or change from one position, direction, or state to another.", "The wind shifted to the north.", ["change", "move"], None),
        ("noun", "A change in emphasis, direction, or policy.", "There has been a shift in public opinion.", ["change"], None),
    ],
    "ship": [
        ("noun", "A large vessel for transporting people or goods by sea.", "The ship sailed out of the harbor at dawn.", None, None),
        ("verb", "To send or transport goods from one place to another.", "The company ships orders within two business days.", ["send", "transport"], None),
    ],
    "shoot": [
        ("verb", "To fire a weapon or discharge a projectile.", "The hunter shot at the target.", None, None),
        ("verb", "To film or photograph something.", "The crew shot the movie on location.", ["film"], None),
        ("noun", "A new growth on a plant, such as a stem or bud.", "New shoots appeared on the rose bush after the rain.", None, None),
    ],
    "shop": [
        ("noun", "A building or part of a building where goods or services are sold.", "She bought bread from the corner shop.", ["store"], None),
        ("verb", "To go to shops in order to buy things.", "They went shopping for new shoes.", None, None),
    ],
    "show": [
        ("verb", "To allow or cause something to be seen.", "She showed him the photos from her trip.", ["display", "reveal"], None),
        ("noun", "A public exhibition or theatrical performance.", "We got tickets to the evening show.", ["performance"], None),
        ("verb", "To prove or demonstrate something.", "The results show a clear improvement.", ["demonstrate", "prove"], None),
    ],
    "sign": [
        ("noun", "A board, notice, or symbol that conveys information or instructions.", "The sign pointed toward the exit.", None, None),
        ("noun", "An indication that something exists, is happening, or may happen.", "Dark clouds were a sign of the coming storm.", ["indication"], None),
        ("verb", "To write one's name on a document to indicate agreement or authorship.", "Please sign the contract on the last page.", None, None),
    ],
    "sink": [
        ("verb", "To go down below the surface of a liquid, or descend gradually.", "The ship began to sink after hitting the iceberg.", None, ["float"]),
        ("noun", "A fixed basin with a water supply and drain, used for washing.", "He washed the dishes in the kitchen sink.", None, None),
        ("verb", "To decline or decrease in amount, quality, or value.", "Morale sank after the layoffs.", ["decline"], None),
    ],
    "sit": [
        ("verb", "To rest one's body in a position supported by the buttocks rather than the feet.", "Please sit down and make yourself comfortable.", None, ["stand"]),
        ("verb", "To be located in a particular place.", "The house sits on a hill overlooking the valley.", ["stand", "rest"], None),
    ],
    "slip": [
        ("verb", "To slide accidentally and lose one's balance or footing.", "She slipped on the icy sidewalk.", None, None),
        ("noun", "A small mistake or minor error.", "It was just a slip of the tongue.", ["mistake", "error"], None),
        ("noun", "A small piece of paper, often used for a note or receipt.", "He wrote his number on a slip of paper.", None, None),
    ],
    "spot": [
        ("noun", "A small round mark differing in color or texture from the surrounding surface.", "The leopard is known for its distinctive spots.", ["mark"], None),
        ("noun", "A particular place or location.", "This is a great spot for a picnic.", ["place", "location"], None),
        ("verb", "To notice or catch sight of someone or something.", "She spotted her friend across the room.", ["notice", "see"], None),
    ],
    "stage": [
        ("noun", "A raised platform in a theater or hall on which performers stand.", "The band walked onto the stage to loud applause.", None, None),
        ("noun", "A point, period, or step in a process or development.", "The project is still in the planning stage.", ["phase", "step"], None),
        ("verb", "To organize and present a performance or event.", "The school staged a production of the play.", None, None),
    ],
    "stand": [
        ("verb", "To be in an upright position, supported by one's feet.", "He stood by the door waiting for her.", None, ["sit"]),
        ("noun", "A small stall or structure from which goods are sold or displayed.", "They set up a lemonade stand on the corner.", None, None),
        ("verb", "To tolerate or endure something.", "I can't stand loud noises early in the morning.", ["tolerate", "endure"], None),
    ],
    "star": [
        ("noun", "A luminous celestial body, visible in the night sky as a fixed point of light.", "They counted stars in the clear night sky.", None, None),
        ("noun", "A famous or highly skilled performer or athlete.", "She became a movie star after her first film.", ["celebrity"], None),
        ("verb", "To have a leading role in a film, play, or show.", "He starred in several action movies.", None, None),
    ],
    "state": [
        ("noun", "The particular condition that someone or something is in at a specific time.", "The house was left in a state of disrepair.", ["condition"], None),
        ("noun", "A nation or territory considered as an organized political community under one government.", "Texas is the second-largest state in the U.S.", None, None),
        ("verb", "To express something clearly and definitely in speech or writing.", "Please state your name for the record.", ["declare", "express"], None),
    ],
    "stick": [
        ("noun", "A thin piece of wood, typically a fallen branch.", "The dog fetched the stick from the yard.", None, None),
        ("verb", "To adhere or become attached to a surface.", "The label wouldn't stick to the wet bottle.", ["adhere"], None),
        ("verb", "To persist with or remain faithful to something.", "She decided to stick with her original plan.", ["persist", "continue"], None),
    ],
    "stock": [
        ("noun", "The goods or merchandise kept on the premises of a shop or business.", "The store is out of stock on that item.", ["inventory"], None),
        ("noun", "A share representing partial ownership in a company.", "He invested in technology stocks.", None, None),
        ("verb", "To have or keep a supply of goods available for sale.", "The pharmacy stocks a wide range of vitamins.", None, None),
    ],
    "stop": [
        ("verb", "To cease moving or operating.", "The car stopped at the red light.", None, ["start"]),
        ("noun", "A place where a bus, train, or other vehicle regularly stops to pick up or drop off passengers.", "Get off at the next bus stop.", None, None),
        ("verb", "To prevent something from continuing or happening.", "They tried to stop the leak before it got worse.", ["prevent", "halt"], None),
    ],
    "store": [
        ("noun", "A retail establishment where goods are sold.", "She bought groceries at the store.", ["shop"], None),
        ("verb", "To keep something for future use.", "They store extra blankets in the closet.", ["keep", "stock"], None),
    ],
    "storm": [
        ("noun", "A violent disturbance of the atmosphere with strong winds and often rain, thunder, or snow.", "A storm knocked out power across the city.", None, None),
        ("verb", "To move angrily or forcefully.", "He stormed out of the meeting in frustration.", None, None),
    ],
    "strike": [
        ("verb", "To hit someone or something forcefully.", "Lightning struck the old oak tree.", ["hit"], None),
        ("noun", "A refusal by employees to work, organized as a form of protest.", "The workers went on strike for better pay.", None, None),
        ("verb", "To occur suddenly and have a strong effect on someone.", "It suddenly struck her that she had forgotten her keys.", ["occur to"], None),
    ],
    "stroke": [
        ("noun", "A sudden loss of brain function caused by an interruption of blood flow to the brain.", "He suffered a stroke last year and is now recovering.", None, None),
        ("noun", "A single movement of a pen, brush, or similar tool.", "She painted the sky with broad strokes.", None, None),
        ("verb", "To move one's hand gently over a surface, especially in affection.", "She stroked the cat's soft fur.", ["caress"], None),
    ],
    "style": [
        ("noun", "A distinctive appearance, typically determined by the principles according to which something is designed.", "The house was built in a modern style.", ["design", "manner"], None),
        ("noun", "A fashionable manner of dress or living.", "She has always had great style.", None, None),
        ("verb", "To design or arrange something, especially hair, in a particular way.", "The stylist styled her hair for the wedding.", None, None),
    ],
    "subject": [
        ("noun", "A branch of knowledge studied or taught, especially in school.", "Math is her favorite subject.", None, None),
        ("noun", "A person or thing that is being discussed, described, or dealt with.", "The subject of the painting is a young woman.", ["topic"], None),
        ("adjective", "Likely to be affected by or dependent on something.", "Prices are subject to change without notice.", None, None),
    ],
    "swing": [
        ("verb", "To move back and forth or from side to side while suspended.", "The pendulum swung steadily back and forth.", None, None),
        ("noun", "A seat suspended by ropes or chains, on which someone can sit and swing.", "The kids played on the swing at the park.", None, None),
        ("noun", "A change from one state, opinion, or amount to another.", "There was a big swing in public opinion.", ["shift", "change"], None),
    ],
    "tap": [
        ("noun", "A device for controlling the flow of liquid or gas from a pipe or container.", "She turned on the tap to fill the kettle.", ["faucet"], None),
        ("verb", "To strike something quickly and lightly.", "He tapped his fingers on the desk while waiting.", None, None),
        ("verb", "To make use of a resource or supply.", "The company tapped into a new market.", ["utilize", "access"], None),
    ],
    "tie": [
        ("verb", "To attach or fasten something with a cord, string, or similar material.", "She tied her shoelaces before the race.", ["fasten", "bind"], None),
        ("noun", "A long, narrow piece of fabric worn around the neck, tied in a knot at the front.", "He wore a blue tie to the interview.", None, None),
        ("noun", "A result in a competition in which two or more competitors have the same score.", "The game ended in a tie.", ["draw"], None),
    ],
    "tip": [
        ("noun", "The pointed or rounded end of something.", "The tip of the pencil snapped.", None, None),
        ("noun", "A small piece of advice about something practical.", "She gave me a helpful tip for cooking rice.", ["hint", "advice"], None),
        ("verb", "To give a small amount of money to someone for a service, in addition to the basic price.", "We tipped the waiter generously.", None, None),
    ],
    "top": [
        ("noun", "The highest point, part, or surface of something.", "They reached the top of the mountain by noon.", None, ["bottom"]),
        ("adjective", "Highest in position, rank, or degree.", "She is the top student in her class.", ["highest", "best"], None),
        ("verb", "To be greater than or exceed a previous amount or level.", "Sales this quarter topped last year's record.", ["exceed", "surpass"], None),
    ],
    "train": [
        ("noun", "A series of connected railway carriages or wagons pulled by a locomotive.", "They took the train into the city.", None, None),
        ("verb", "To teach a person or animal a particular skill or type of behavior through practice.", "She trains every day for the marathon.", ["coach", "practice"], None),
    ],
    "trip": [
        ("noun", "A journey or excursion, especially for pleasure.", "They planned a trip to the mountains.", ["journey", "excursion"], None),
        ("verb", "To catch one's foot on something and stumble or fall.", "He tripped over the curb and nearly fell.", ["stumble"], None),
    ],
    "trust": [
        ("noun", "Firm belief in the reliability, truth, or ability of someone or something.", "It takes time to build trust in a relationship.", None, ["distrust"]),
        ("verb", "To believe in the reliability, truth, or ability of someone or something.", "You can trust him to finish the job on time.", ["believe in", "rely on"], None),
    ],
    "turn": [
        ("verb", "To move in a circular direction, wholly or partly, around an axis or point.", "She turned the key to unlock the door.", None, None),
        ("noun", "An opportunity or obligation to do something that comes after or in alternation with others.", "It's your turn to choose the movie.", ["chance"], None),
        ("verb", "To change direction while traveling.", "Turn left at the next intersection.", None, None),
    ],
    "type": [
        ("noun", "A category of people or things having common characteristics.", "What type of music do you like?", ["kind", "sort"], None),
        ("verb", "To write something using a keyboard.", "She typed the report in less than an hour.", None, None),
    ],
    "use": [
        ("verb", "To take, hold, or deploy something as a means of accomplishing a purpose.", "You can use my pen if you need one.", None, None),
        ("noun", "The action of using something, or the state of being used.", "The tool is still in use after all these years.", ["usage"], None),
        ("verb", "To exploit someone or something unfairly for one's own advantage.", "He felt used by his so-called friend.", ["exploit"], None),
    ],
    "view": [
        ("noun", "The ability to see something from a particular place; a scene or vista.", "The hotel room had a stunning view of the ocean.", ["vista", "scene"], None),
        ("noun", "A personal opinion or way of thinking about something.", "In my view, the plan needs more detail.", ["opinion"], None),
        ("verb", "To look at or regard something in a particular way.", "She views the challenge as an opportunity.", ["regard", "consider"], None),
    ],
    "wave": [
        ("noun", "A moving ridge of water on the surface of the sea or another body of water.", "The surfer caught a huge wave.", None, None),
        ("verb", "To move one's hand back and forth as a greeting or signal.", "She waved goodbye from the platform.", None, None),
        ("noun", "A sudden occurrence or increase of a phenomenon or emotion.", "A wave of relief washed over him.", ["surge"], None),
    ],
    "wear": [
        ("verb", "To have something on one's body as clothing, jewelry, or protection.", "She wore a red dress to the party.", None, None),
        ("verb", "To become damaged or thinner through friction or use over time.", "The tires had worn down after years of driving.", ["erode"], None),
        ("noun", "Clothing of a particular type.", "The store specializes in outdoor wear.", None, None),
    ],
    "wind": [
        ("noun", "The perceptible natural movement of air, especially in the form of a current blowing from a particular direction.", "A strong wind blew leaves across the yard.", None, None),
        ("verb", "To turn or twist something, such as a handle or key, repeatedly.", "He wound the old clock every night.", ["twist", "turn"], None),
        ("verb", "Of a road, river, or similar feature, to follow a curving course.", "The path winds through the forest.", ["meander"], None),
    ],
    "work": [
        ("noun", "Activity involving mental or physical effort done to achieve a purpose or result, especially as part of one's job.", "She has a lot of work to finish before Friday.", ["labor"], None),
        ("verb", "To perform tasks or duties, especially as part of a job.", "He works at a hospital downtown.", None, None),
        ("verb", "To function or operate effectively.", "The new plan seems to be working well.", ["function"], None),
    ],
    "yield": [
        ("verb", "To produce or provide a result, profit, or benefit.", "The investment yielded a healthy return.", ["produce", "generate"], None),
        ("verb", "To give way to pressure, argument, or force.", "Drivers must yield to pedestrians at the crosswalk.", ["give way", "submit"], None),
        ("noun", "The amount produced or obtained through a process, especially in agriculture or finance.", "Farmers reported a strong yield this harvest.", ["output"], None),
    ],
    "key": [
        ("noun", "A small metal instrument used to operate a lock by inserting it and turning it.", "She lost her house key on the way home.", None, None),
        ("adjective", "Of crucial importance; essential.", "Trust is a key factor in any relationship.", ["essential", "crucial"], None),
        ("noun", "A set of musical notes based on a particular scale that gives a piece of music its tonal center.", "The song is written in the key of C major.", None, None),
    ],
    "letter": [
        ("noun", "A character representing one or more sounds used in writing a language.", "The word 'cat' has three letters.", None, None),
        ("noun", "A written, typed, or printed message sent to another person, usually by mail.", "She wrote a letter to her grandmother.", None, None),
    ],
    "paper": [
        ("noun", "Material made from wood pulp or other fibrous substances, used for writing, printing, or wrapping.", "He wrote his notes on a sheet of paper.", None, None),
        ("noun", "A newspaper.", "She reads the paper every morning with coffee.", None, None),
        ("noun", "A piece of academic writing, presented for evaluation or publication.", "The professor published a paper on climate change.", ["essay", "article"], None),
    ],
    "current": [
        ("adjective", "Belonging to the present time; happening now.", "The current situation is improving.", ["present"], ["former"]),
        ("noun", "A continuous movement of water, air, or electricity in a particular direction.", "The swimmer was caught in a strong current.", None, None),
    ],
}


def create_schema(conn: sqlite3.Connection) -> None:
    """Drops and recreates the `entries` table, so the script is idempotent."""
    conn.execute("DROP TABLE IF EXISTS entries")
    conn.execute(
        """
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            word TEXT NOT NULL,
            part_of_speech TEXT,
            definition TEXT NOT NULL,
            example TEXT,
            synonyms TEXT,
            antonyms TEXT,
            sense_index INTEGER NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX idx_entries_word ON entries(word)")


def _join_or_none(values: list[str] | None) -> str | None:
    if not values:
        return None
    return "|".join(values)


def _insert_rows(conn: sqlite3.Connection, rows: Iterable[tuple]) -> int:
    cursor = conn.executemany(
        """
        INSERT INTO entries (word, part_of_speech, definition, example, synonyms, antonyms, sense_index)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    return cursor.rowcount if cursor.rowcount is not None and cursor.rowcount >= 0 else -1


def seed_from_data(conn: sqlite3.Connection) -> tuple[int, int]:
    """Populates `entries` from the embedded WORDS dataset.

    Returns (word_count, row_count).
    """
    rows = []
    for word, senses in WORDS.items():
        normalized = word.strip().lower()
        for sense_index, (pos, definition, example, synonyms, antonyms) in enumerate(senses):
            rows.append(
                (
                    normalized,
                    pos,
                    definition,
                    example,
                    _join_or_none(synonyms),
                    _join_or_none(antonyms),
                    sense_index,
                )
            )
    _insert_rows(conn, rows)
    return len(WORDS), len(rows)


def ingest_wordnet(conn: sqlite3.Connection, path: Path) -> tuple[int, int]:
    """Populates `entries` from a flat WordNet-derived JSON file.

    See the module docstring for the exact expected JSON shape. Entries are
    grouped by word in the order encountered in the file, and sense_index is
    assigned per word from that order.
    """
    with path.open("r", encoding="utf-8") as f:
        raw_entries = json.load(f)

    if not isinstance(raw_entries, list):
        raise ValueError("Expected the WordNet JSON file to contain a top-level list of sense objects.")

    sense_counters: dict[str, int] = {}
    rows = []
    words_seen: set[str] = set()

    for i, item in enumerate(raw_entries):
        if "word" not in item or "definition" not in item:
            raise ValueError(f"Entry at index {i} is missing required field 'word' or 'definition': {item!r}")

        normalized = str(item["word"]).strip().lower()
        definition = str(item["definition"])
        pos = item.get("part_of_speech")
        example = item.get("example")
        synonyms = item.get("synonyms")
        antonyms = item.get("antonyms")

        sense_index = sense_counters.get(normalized, 0)
        sense_counters[normalized] = sense_index + 1
        words_seen.add(normalized)

        rows.append(
            (
                normalized,
                pos,
                definition,
                example,
                _join_or_none(synonyms),
                _join_or_none(antonyms),
                sense_index,
            )
        )

    _insert_rows(conn, rows)
    return len(words_seen), len(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the SmartNotes offline dictionary.sqlite database.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--seed",
        action="store_true",
        help="Build the database from the curated starter word list embedded in this script.",
    )
    mode.add_argument(
        "--wordnet",
        metavar="PATH",
        type=Path,
        help="Build the database by ingesting a WordNet-derived JSON file at PATH (see module docstring for shape).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output .sqlite path (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Remove any existing file first so a stale WAL/journal from a previous
    # run never lingers next to a freshly rebuilt database.
    if args.output.exists():
        args.output.unlink()

    conn = sqlite3.connect(str(args.output))
    try:
        create_schema(conn)
        if args.seed:
            word_count, row_count = seed_from_data(conn)
            source = "seed dataset"
        else:
            word_count, row_count = ingest_wordnet(conn, args.wordnet)
            source = f"WordNet JSON ({args.wordnet})"
        conn.commit()
    finally:
        conn.close()

    print(f"Built {args.output} from {source}")
    print(f"  words: {word_count}")
    print(f"  rows:  {row_count}")


if __name__ == "__main__":
    main()
