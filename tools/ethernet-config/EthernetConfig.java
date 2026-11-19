import java.lang.reflect.Array;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Collection;

/**
 * Dump/restore Ethernet IpConfiguration through IEthernetManager.
 *
 * No compile-time Android dependency: everything is reflection so the class
 * can be built with a plain JDK and dexed with d8.
 *
 * Usage:
 *   EthernetConfig dump vlan11 vlan21
 *   EthernetConfig set <iface> DHCP
 *   EthernetConfig set <iface> UNASSIGNED
 *   EthernetConfig set <iface> STATIC <ip/prefix> <gateway|none> [dnsCsv] [domainsCsv]
 *   EthernetConfig static <iface> <ip/prefix> <gateway|none> [dnsCsv] [domainsCsv]
 *   EthernetConfig dhcp <iface>
 *   EthernetConfig unassigned <iface>
 *
 * dump output is one line per interface:
 *   iface|ASSIGNMENT|cidr|gateway|dns1,dns2|domain1,domain2
 * For non-STATIC assignments only "iface|ASSIGNMENT" is printed.
 */
public final class EthernetConfig {
    private static final String ETH_SERVICE = "ethernet";

    public static void main(String[] args) {
        try {
            if (args.length == 0) {
                usage();
                return;
            }

            Object ethernet = getEthernetService();
            if (ethernet == null) {
                System.out.println("ERROR: ethernet service is null");
                System.exit(1);
                return;
            }

            Class<?> iem = Class.forName("android.net.IEthernetManager");
            Method getConfiguration = iem.getMethod("getConfiguration", String.class);
            Class<?> ipConfiguration = Class.forName("android.net.IpConfiguration");
            Method setConfiguration = iem.getMethod("setConfiguration", String.class, ipConfiguration);
            Class<?> ipAssignment = Class.forName("android.net.IpConfiguration$IpAssignment");
            Method getIpAssignment = ipConfiguration.getMethod("getIpAssignment");
            Method setIpAssignment = ipConfiguration.getMethod("setIpAssignment", ipAssignment);
            Class<?> staticIpConfiguration = Class.forName("android.net.StaticIpConfiguration");
            Method getStatic = ipConfiguration.getMethod("getStaticIpConfiguration");
            Method setStatic = ipConfiguration.getMethod("setStaticIpConfiguration", staticIpConfiguration);

            Class<?> linkAddress = Class.forName("android.net.LinkAddress");
            Constructor<?> linkCtor = linkAddress.getDeclaredConstructor(InetAddress.class, int.class);
            linkCtor.setAccessible(true);
            Constructor<?> staticCtor = staticIpConfiguration.getDeclaredConstructor();
            staticCtor.setAccessible(true);
            Field ipAddressField = staticIpConfiguration.getDeclaredField("ipAddress");
            Field gatewayField = staticIpConfiguration.getDeclaredField("gateway");
            Field dnsField = staticIpConfiguration.getDeclaredField("dnsServers");
            Field domainsField = staticIpConfiguration.getDeclaredField("domains");
            ipAddressField.setAccessible(true);
            gatewayField.setAccessible(true);
            dnsField.setAccessible(true);
            domainsField.setAccessible(true);

            String mode = args[0].toLowerCase();
            if ("dump".equals(mode)) {
                if (args.length < 2) {
                    usage();
                    return;
                }
                for (int i = 1; i < args.length; i++) {
                    dumpInterface(ethernet, getConfiguration, getIpAssignment, getStatic,
                            ipAddressField, gatewayField, dnsField, domainsField, args[i]);
                }
                return;
            }

            if ("set".equals(mode) || "static".equals(mode) ||
                    "dhcp".equals(mode) || "unassigned".equals(mode)) {
                String iface;
                String assignment;
                String cidr = "";
                String gateway = "none";
                String dnsCsv = "";
                String domainsCsv = "";

                if ("set".equals(mode)) {
                    if (args.length < 3) {
                        usage();
                        return;
                    }
                    iface = args[1];
                    assignment = args[2].toUpperCase();
                    if ("STATIC".equals(assignment)) {
                        if (args.length < 5) {
                            usage();
                            return;
                        }
                        cidr = args[3];
                        gateway = args[4];
                        if (args.length > 5) dnsCsv = args[5];
                        if (args.length > 6) domainsCsv = args[6];
                    }
                } else if ("static".equals(mode)) {
                    if (args.length < 4) {
                        usage();
                        return;
                    }
                    iface = args[1];
                    assignment = "STATIC";
                    cidr = args[2];
                    gateway = args[3];
                    if (args.length > 4) dnsCsv = args[4];
                    if (args.length > 5) domainsCsv = args[5];
                } else {
                    if (args.length < 2) {
                        usage();
                        return;
                    }
                    iface = args[1];
                    assignment = "dhcp".equals(mode) ? "DHCP" : "UNASSIGNED";
                }

                Object config = getConfiguration.invoke(ethernet, iface);
                if (config == null) {
                    System.out.println("ERROR: " + iface + ": no IpConfiguration");
                    System.exit(1);
                    return;
                }

                Object assignmentValue = Enum.valueOf(asEnumClass(ipAssignment), assignment);
                setIpAssignment.invoke(config, assignmentValue);

                if ("STATIC".equals(assignment)) {
                    Object staticConfig = staticCtor.newInstance();
                    String[] parts = cidr.split("/");
                    if (parts.length != 2) {
                        System.out.println("ERROR: bad CIDR " + cidr);
                        System.exit(1);
                        return;
                    }
                    InetAddress address = InetAddress.getByName(parts[0]);
                    int prefix = Integer.parseInt(parts[1]);
                    ipAddressField.set(staticConfig, linkCtor.newInstance(address, prefix));

                    InetAddress gatewayAddress = null;
                    if (!"none".equalsIgnoreCase(gateway)) {
                        gatewayAddress = InetAddress.getByName(gateway);
                    }
                    gatewayField.set(staticConfig, gatewayAddress);

                    ArrayList<InetAddress> dns = new ArrayList<InetAddress>();
                    for (String item : splitCsv(dnsCsv)) {
                        dns.add(InetAddress.getByName(item));
                    }
                    dnsField.set(staticConfig, dns);

                    ArrayList<String> domains = new ArrayList<String>();
                    for (String item : splitCsv(domainsCsv)) {
                        domains.add(item);
                    }
                    domainsField.set(staticConfig, domains);

                    setStatic.invoke(config, staticConfig);
                } else {
                    setStatic.invoke(config, new Object[]{null});
                }

                setConfiguration.invoke(ethernet, iface, config);
                System.out.println(iface + "|" + assignment);
                return;
            }

            usage();
        } catch (Throwable t) {
            System.out.println("ERROR: " + t);
            t.printStackTrace(System.out);
            System.exit(1);
        }
    }

    private static void dumpInterface(Object ethernet, Method getConfiguration,
                                      Method getIpAssignment, Method getStatic,
                                      Field ipAddressField, Field gatewayField,
                                      Field dnsField, Field domainsField,
                                      String iface) throws Exception {
        Object config = getConfiguration.invoke(ethernet, iface);
        if (config == null) {
            System.out.println(iface + "|MISSING");
            return;
        }
        Object assignment = getIpAssignment.invoke(config);
        String assignmentName = String.valueOf(assignment);
        Object staticConfig = getStatic.invoke(config);
        if (staticConfig == null) {
            System.out.println(iface + "|" + assignmentName);
            return;
        }
        Object link = ipAddressField.get(staticConfig);
        Object gateway = gatewayField.get(staticConfig);
        Object dns = dnsField.get(staticConfig);
        Object domains = domainsField.get(staticConfig);
        System.out.println(iface + "|" + assignmentName + "|" +
                (link == null ? "" : link.toString()) + "|" +
                (gateway == null ? "none" : formatAddress(gateway)) + "|" +
                joinCollection(dns) + "|" + joinCollection(domains));
    }

    private static String formatAddress(Object value) {
        if (value instanceof InetAddress) {
            return ((InetAddress) value).getHostAddress();
        }
        return stripSlash(String.valueOf(value));
    }

    private static String stripSlash(String value) {
        return value.startsWith("/") ? value.substring(1) : value;
    }

    private static String joinCollection(Object value) {
        if (value == null) return "";
        StringBuilder builder = new StringBuilder();
        if (value instanceof Collection) {
            for (Object item : (Collection<?>) value) {
                if (builder.length() > 0) builder.append(',');
                builder.append(formatAddress(item));
            }
            return builder.toString();
        }
        if (value.getClass().isArray()) {
            int length = Array.getLength(value);
            for (int i = 0; i < length; i++) {
                if (builder.length() > 0) builder.append(',');
                builder.append(formatAddress(Array.get(value, i)));
            }
        }
        return builder.toString();
    }

    private static String[] splitCsv(String value) {
        if (value == null || value.trim().isEmpty()) {
            return new String[0];
        }
        return value.split(",");
    }

    private static Object getEthernetService() throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        Object binder = serviceManager.getMethod("getService", String.class).invoke(null, ETH_SERVICE);
        if (binder == null) {
            return null;
        }
        Class<?> stub = Class.forName("android.net.IEthernetManager$Stub");
        Method asInterface = stub.getMethod("asInterface", Class.forName("android.os.IBinder"));
        return asInterface.invoke(null, binder);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private static Class<? extends Enum> asEnumClass(Class<?> clazz) {
        return (Class<? extends Enum>) clazz;
    }

    private static void usage() {
        System.out.println("usage:");
        System.out.println("  EthernetConfig dump <iface> [iface...]");
        System.out.println("  EthernetConfig set <iface> DHCP|UNASSIGNED");
        System.out.println("  EthernetConfig set <iface> STATIC <ip/prefix> <gateway|none> [dnsCsv] [domainsCsv]");
        System.out.println("  EthernetConfig static <iface> <ip/prefix> <gateway|none> [dnsCsv] [domainsCsv]");
        System.out.println("  EthernetConfig dhcp <iface>");
        System.out.println("  EthernetConfig unassigned <iface>");
    }
}
