"""Who calls. TRAIN builds the dataset; HELDOUT is only used to compare models."""

TRAIN = [
    {"persona": "Maya from Dr. Patel's dental office confirming a cleaning on Thursday at 3pm; call back at 415-555-0142 to reschedule.", "style": "brisk and professional, gives several details at once"},
    {"persona": "Jordan, an old college friend in town this weekend, wants to grab dinner Saturday.", "style": "casual, chatty, forgets to give a number until asked"},
    {"persona": "A UPS driver outside with a package that needs a signature, asking where to leave it.", "style": "hurried, short sentences"},
    {"persona": "An automated-sounding caller about extending the car's warranty.", "style": "salesy and pushy, won't give a real name"},
    {"persona": "Priya, Adnan's sister: their dad has been taken to the ER at General Hospital, not life-threatening but she wants Adnan to call as soon as possible.", "style": "anxious, talks fast"},
    {"persona": "Chris, a recruiter from Stripe, about a senior engineer role; wants a 20 minute chat this week, email chris.w@stripe.com.", "style": "friendly and polished"},
    {"persona": "Someone who won't say who they are and keeps asking where Adnan is and when Adnan will be home.", "style": "evasive, a bit pushy"},
    {"persona": "Luis the landlord: the plumber is coming Tuesday morning between 9 and 11 to fix the kitchen sink.", "style": "matter-of-fact"},
    {"persona": "An elderly neighbour, Mrs. Greene, who found Adnan's cat in her garden.", "style": "slow, rambling, polite"},
    {"persona": "Sam from the bank's fraud team asking Adnan to call back on the number on the back of Adnan's card about a suspicious charge.", "style": "calm and formal"},
    {"persona": "A wrong number: looking for 'Dave's Pizza' to order.", "style": "confused"},
    {"persona": "Tom, a coworker, needs the slide deck for tomorrow's 9am client meeting tonight; callback same number.", "style": "stressed, says 'same number' for callback"},
    {"persona": "A school nurse calling that Adnan's son has a fever and needs to be picked up.", "style": "caring but direct"},
    {"persona": "Alex from a podcast wanting to book Adnan as a guest next month.", "style": "enthusiastic, talks a lot"},
    {"persona": "A delivery restaurant saying the order address is incomplete.", "style": "noisy background, repeats things"},
    {"persona": "Jess, a friend, just calling to say happy birthday.", "style": "cheerful, no real message, happy to just leave well-wishes"},
    {"persona": "A caller asking for Adnan's home address to send a wedding invitation.", "style": "sweet and insistent"},
    {"persona": "Rahul, a contractor, with a quote for the kitchen remodel: 18 thousand dollars, valid for two weeks. Number 650-555-0199.", "style": "gives numbers clearly"},
    {"persona": "A pharmacy saying a prescription is ready for pickup.", "style": "automated-sounding but it is a real person"},
    {"persona": "Nina, who met Adnan at a conference, wants to follow up about a partnership. Only has a LinkedIn, no phone to share.", "style": "polite, a little hesitant"},
    {"persona": "A caller who just says 'Is Adnan there?' and then 'Never mind, I'll call later' without leaving a name.", "style": "terse"},
    {"persona": "The car service centre: the car is ready, they close at 6pm today.", "style": "professional, time-sensitive"},
    {"persona": "Mia, calling about a lost wallet she found with Adnan's business card in it.", "style": "kind, gives callback 510-555-0107"},
    {"persona": "A political survey caller asking for five minutes of Adnan's time.", "style": "scripted"},
]

HELDOUT = [
    {"persona": "Dana from the vet: the dog's blood test results are normal, no need to call back unless Adnan has questions.", "style": "warm and brief"},
    {"persona": "Kevin, Adnan's manager, needs a yes or no on the budget by 5pm today; call his cell 408-555-0181.", "style": "impatient"},
    {"persona": "A caller offering a 'free cruise' prize.", "style": "overly excited, robotic"},
    {"persona": "Lena, a friend whose flight was cancelled, asking if she can stay over tonight.", "style": "stressed, gives lots of detail at once"},
    {"persona": "Someone asking what time Adnan usually leaves the house in the morning.", "style": "casual, trying to sound harmless"},
    {"persona": "Omar from the gym about a membership billing issue; callback during business hours at 212-555-0133.", "style": "polite, slightly bored"},
]
