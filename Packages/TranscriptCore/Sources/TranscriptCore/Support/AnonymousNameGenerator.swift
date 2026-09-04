import Foundation

/// Deterministic animal-name pool for new speakers (PLAN Phase 2d).
/// Sized for a lifetime cross-meeting speaker library, not a single meeting (PLAN §9.2).
public enum AnonymousNameGenerator {
    public static let pool: [String] = [
        "Hippo", "Otter", "Badger", "Falcon", "Heron", "Lynx", "Marmot", "Narwhal",
        "Ocelot", "Puffin", "Quokka", "Raven", "Stoat", "Tapir", "Urchin", "Vicuna",
        "Walrus", "Yak", "Zebu", "Ibex", "Jackal", "Kestrel", "Lemur", "Manatee",
        "Alpaca", "Antelope", "Armadillo", "Axolotl", "Beaver", "Bison", "Bobcat",
        "Buffalo", "Bullfrog", "Camel", "Capybara", "Caribou", "Cheetah", "Chinchilla",
        "Cobra", "Condor", "Coyote", "Crane", "Dingo", "Dolphin", "Donkey", "Eagle",
        "Egret", "Elk", "Emu", "Ferret", "Finch", "Flamingo", "Fox", "Gazelle",
        "Gecko", "Gibbon", "Giraffe", "Gopher", "Grouse", "Hamster", "Hare",
        "Hedgehog", "Hornbill", "Impala", "Iguana", "Jaguar", "Jay", "Kangaroo",
        "Kingfisher", "Kiwi", "Koala", "Kudu", "Ladybug", "Lapwing", "Llama",
        "Lobster", "Macaw", "Magpie", "Mallard", "Marten", "Meerkat", "Mink", "Mole",
        "Mongoose", "Moose", "Muskox", "Newt", "Nightingale", "Nutria", "Okapi",
        "Opossum", "Oriole", "Oryx", "Osprey", "Ostrich", "Owl", "Panda", "Pangolin",
        "Parrot", "Peacock", "Pelican", "Penguin", "Pheasant", "Pigeon", "Platypus",
        "Pony", "Porcupine", "Puma", "Quail", "Rabbit", "Raccoon", "Reindeer",
        "Robin", "Salamander", "Seal", "Serval", "Sparrow", "Squirrel", "Starling",
        "Swan", "Tamarin", "Toucan", "Turtle", "Wallaby", "Warbler", "Weasel",
        "Wombat", "Woodpecker", "Wren"
    ]

    /// First unused pool name; only once the whole pool is exhausted does it fall
    /// back to a numeric suffix ("Hippo 2").
    public static func nextName(usedNames: some Sequence<String>) -> String {
        let used = Set(usedNames)
        var round = 1
        while true {
            for name in pool {
                let candidate = round == 1 ? name : "\(name) \(round)"
                if !used.contains(candidate) { return candidate }
            }
            round += 1
        }
    }
}
